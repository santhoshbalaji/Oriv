import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI

/// A drag is scoped to this controller, so another profile/window cannot move it.
struct SidebarTabTransfer: Codable {
    let id: UUID
    let owner: UUID
}

enum SidebarDropTarget { case tab(UUID), pinned(Bool) }
enum SidebarTabCommand { case pin, duplicate, moveUp, moveDown, reload, copyLink, mute, media, close, newPrivate }

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
        case .reload: tab.reload()
        case .copyLink: if let url = tab.url { PrivacyPasteboard.copy(url) }
        case .mute: tab.toggleAudioMute()
        case .media: tab.toggleMediaSuspension()
        case .close: controller.requestCloseTab(tab.id)
        case .newPrivate: controller.newTab(isPrivate: true)
        }
    }
    static func filtered(_ tabs: [BrowserTab], query: String) -> [BrowserTab] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tabs.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.hostname.localizedCaseInsensitiveContains(query) }
    }
    static func duplicateTitles(in tabs: [BrowserTab]) -> Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for tab in tabs where !seen.insert(tab.displayTitle).inserted {
            duplicates.insert(tab.displayTitle)
        }
        return duplicates
    }

    static func muteLabel(_ tab: BrowserTab) -> String { tab.isAudioMuted ? "Unmute Tab" : "Mute Tab" }

    static func label(_ tab: BrowserTab, selected: Bool) -> String {
        ([tab.displayTitle, tab.hostname] + (selected ? ["Selected"] : []) +
         (tab.isPinned ? ["Pinned"] : []) + (tab.isPrivate ? ["Private"] : []) +
         (tab.isLoading ? ["Loading"] : []) + (tab.isAudioMuted ? ["Muted"] : []) +
         (tab.mediaSuspended ? ["Media paused"] : (tab.isPlayingAudio && !tab.isAudioMuted ? ["Playing audio"] : [])))
            .joined(separator: ", ")
    }
    static func canDrop(_ item: SidebarTabTransfer, on target: SidebarDropTarget, controller: BrowserController) -> Bool {
        guard item.owner == controller.sidebarDragID,
              let source = controller.session.tabs.first(where: { $0.id == item.id }) else { return false }
        switch target {
        case .pinned: return !source.isPrivate
        case .tab(let id):
            guard let destination = controller.session.tabs.first(where: { $0.id == id }) else { return false }
            return source.id != id && source.isPrivate == destination.isPrivate && source.isPinned == destination.isPinned
        }
    }

    static func drop(_ items: [SidebarTabTransfer], on target: SidebarDropTarget, controller: BrowserController) -> Bool {
        guard items.count == 1, let item = items.first, canDrop(item, on: target, controller: controller) else { return false }
        switch target {
        case .pinned(let pinned): controller.session.moveTab(item.id, intoPinnedSection: pinned)
        case .tab(let id): controller.session.moveTab(item.id, to: id)
        }
        return true
    }
}

private struct SidebarProfileCover: ViewModifier {
    var switcher: ProfileSidebarSwitch?
    func body(content: Content) -> some View {
        content.opacity(switcher?.isCovering == true ? 0 : 1)
    }
}

struct BrowserSidebar: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.sidebarContrast) private var contrast
    @Bindable var controller: BrowserController
    var profiles: BrowserProfiles? = nil
    @State var tabList = SidebarListHandle()
    var profileTrailingInset: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @FocusState private var utilityFocus: String?
    private var session: BrowserSession { controller.session }
    private var privateWindow: Bool { session.isExternalPrivate || controller.profile == nil }
    private var compact: Bool { controller.sidebar.rail }
    private var peeking: Bool { controller.sidebar.peeking }
    private var railLayout: Bool { compact || peeking }
    private var filteredTabs: [BrowserTab] { SidebarTabs.filtered(session.orderedTabs, query: controller.profileUI.settledQuery) }

    var body: some View {
        let tabs = filteredTabs
        return VStack(spacing: railLayout ? 6 : 0) {
            VStack(spacing: railLayout ? 6 : 0) {
                if !railLayout { profileHeader.focused($utilityFocus, equals: "profile") }
                searchField
                if railLayout { newTab }
                if let notice = profiles?.notice, !session.isExternalPrivate, !compact {
                    Text(notice).font(.caption).foregroundStyle(theme.sidebarSecondaryText(contrast)).padding(.horizontal, 14)
                }
                NativeSidebarTabs(controller: controller, profiles: profiles, handle: tabList, tabs: tabs, duplicateTitles: SidebarTabs.duplicateTitles(in: tabs), rail: compact, peek: peeking,
                                  searching: !controller.tabSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { id, right in
                    controller.profileUI.closeToRight = right
                    controller.profileUI.closeOthers = id
                }
                if !railLayout { newTab.padding(.bottom, MacBrowserLayout.sidebarFooterGap) }
            }
            .modifier(SidebarProfileCover(switcher: !railLayout && !privateWindow ? profiles?.sidebarSwitch : nil))
            .background {
                if !railLayout, let profiles, profiles.canSwitchProfiles(from: controller) {
                    ProfileSidebarAnchor(switcher: profiles.sidebarSwitch, controller: controller, list: tabList,
                                         profileTrailingInset: profileTrailingInset)
                }
            }
            .task(id: controller.scoped(profiles.map { $0.available.map(\.id) })) {
                if !privateWindow { await profiles?.warmProfilePreviews() }
            }
            if !railLayout, let profiles, profiles.canSwitchProfiles(from: controller) {
                profileDots(profiles)
            }
            footer
        }
        .padding(.horizontal, railLayout ? 0 : MacBrowserLayout.sidebarInset)
        .padding(.bottom, railLayout ? 0 : MacBrowserLayout.sidebarInset)
        .background {
            if !railLayout, let profiles, profiles.canSwitchProfiles(from: controller) {
                ProfileSidebarSwipeRegion(switcher: profiles.sidebarSwitch, controller: controller, kind: .sidebar)
            }
        }
        .font(OrivType.body)
        .foregroundStyle(theme.text)
        .transformPreference(SidebarKeyboardFocusKey.self) { $0 = $0 || searchFocused || utilityFocus != nil || tabList.hasFocus }
        .task(id: controller.scoped(controller.tabSearch)) {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled else { return }
            controller.profileUI.settledQuery = controller.tabSearch
        }
        .onChange(of: controller.scoped(controller.tabSearchFocusRequest)) { old, new in
            if old.owner == new.owner, !controller.tabSearchPanel { searchFocused = true }
        }
        .onChange(of: controller.sidebarDragID) { _, _ in
            searchFocused = false
            utilityFocus = nil
        }
        .onChange(of: controller.scoped(session.selectedTabID)) { old, new in
            guard old.owner == new.owner else { return }
            let id = new.value
            controller.sidebarTooltip.dismiss()
            if let id, !SidebarTabs.filtered(session.orderedTabs, query: controller.tabSearch).contains(where: { $0.id == id }) { controller.tabSearch = "" }
        }
        .confirmationDialog(controller.profileUI.closeToRight ? "Close tabs to the right?" : "Close other tabs?", isPresented: Binding(get: { controller.profileUI.closeOthers != nil }, set: { if !$0 { controller.profileUI.closeOthers = nil } })) {
            Button("Close Tabs", role: .destructive) { if let id = controller.profileUI.closeOthers { session.closeOtherTabs(id, toRight: controller.profileUI.closeToRight) }; controller.profileUI.closeOthers = nil }
        } message: { Text("Pinned tabs and tabs in the other privacy group stay open. Unsaved website forms in closed tabs may be lost.") }
    }

    private var profileHeader: some View {
        Group {
            if let profiles, !session.isExternalPrivate {
                ProfileMenu(profiles: profiles, iconOnly: compact, tabCount: session.tabs.count)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: privateWindow ? "eyeglasses" : "rectangle.stack").font(.system(size: 17, weight: .semibold))
                    if !compact {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(privateWindow ? "Private" : controller.profile?.name ?? "Personal").font(OrivType.profile)
                            if !session.tabs.isEmpty { Text(SidebarTabs.countLabel(session.tabs.count)).font(OrivType.caption).foregroundStyle(theme.sidebarSecondaryText(contrast)) }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, MacBrowserLayout.sidebarRowInset)
                .foregroundStyle(privateWindow ? theme.sidebarPrivateAccent : theme.text)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(privateWindow ? "Private browsing, \(SidebarTabs.countLabel(session.tabs.count))" : "\(controller.profile?.name ?? "Personal"), \(SidebarTabs.countLabel(session.tabs.count))")
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
                .orivButton(.quiet).focused($utilityFocus, equals: "search")
                .browserGeometryMarker("sidebarSearchGeometry")
                .accessibilityLabel(OrivStrings.searchTabs).help("Search Tabs (⇧⌘A)")
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                .padding(.horizontal, MacBrowserLayout.railInset)
        } else {
            OrivSearchField(text: $controller.tabSearch, shortcut: "⇧⌘A", sidebar: true,
                            focused: searchFocused, ink: theme.sidebarSecondaryText(contrast),
                            clearLabel: "Clear tab search", onClear: { searchFocused = true }) {
                TextField(OrivStrings.searchTabs, text: $controller.tabSearch,
                          prompt: Text(OrivStrings.searchTabs).foregroundStyle(theme.sidebarSecondaryText(contrast)))
                    .focused($searchFocused).accessibilityLabel(OrivStrings.searchTabs).accessibilityIdentifier("tabSearchField")
                    .accessibilityHint("Press Shift-Command-A to focus Search tabs.")
                    .onExitCommand { controller.tabSearch = ""; focusTabAfterSearch(session.selectedTabID) }
                    .onKeyPress(.downArrow) {
                        guard let first = filteredTabs.first else { return .ignored }
                        focusTabAfterSearch(first.id); return .handled
                    }
                    .onSubmit {
                        if let first = filteredTabs.first { focusTabAfterSearch(first.id); session.selectTab(first.id) }
                    }
            }
            .background {
                if searchFocused, let profiles {
                    ProfileSidebarSwipeRegion(switcher: profiles.sidebarSwitch, controller: controller, kind: .editing)
                }
            }
            .browserGeometryMarker("sidebarSearchGeometry")
            .padding(.bottom, 10)
        }
    }

    private func focusTabAfterSearch(_ id: UUID?) {
        searchFocused = false
        // Let SwiftUI release the field editor before installing the native responder.
        DispatchQueue.main.async { tabList.focus(id) }
    }

    private var newTab: some View {
        Button { controller.newTab(isPrivate: session.selectedTab?.isPrivate ?? session.isExternalPrivate) } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").frame(width: railLayout ? 42 : 19)
                if peeking { Text("New Tab").modifier(SidebarLabelFade()); Spacer() }
                if !railLayout { Text("New Tab"); Spacer(); Text("⌘T").font(.system(size: 10)).foregroundStyle(theme.sidebarSecondaryText(contrast)) }
            }.font(OrivType.body).padding(.horizontal, railLayout ? 0 : MacBrowserLayout.sidebarRowInset).frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
        }.orivButton(.quiet).frame(width: compact ? 42 : nil)
            .padding(.horizontal, peeking ? MacBrowserLayout.railInset : 0)
            .browserGeometryMarker("sidebarNewTabGeometry")
            .focused($utilityFocus, equals: "new-tab")
            .accessibilityLabel("New Tab").accessibilityIdentifier(railLayout ? "railNewTabButton" : "newTabButton").help("New Tab (⌘T)")
    }

    private func profileDots(_ profiles: BrowserProfiles) -> some View {
        let available = profiles.available
        let centeredID = utilityFocus.flatMap(UUID.init(uuidString:)) ?? profiles.active.id
        let indexToCenter = available.firstIndex { $0.id == centeredID } ?? 0
        return ProfileDotsScroll(profiles: profiles, count: available.count, indexToCenter: indexToCenter) {
            HStack(spacing: 0) {
                ForEach(Array(available.enumerated()), id: \.element.id) { index, profile in
                    let selected = profile.id == profiles.active.id
                    Button {
                        profiles.switchFromSidebar(profile.id, source: controller)
                    } label: {
                        Circle()
                            .fill(selected ? theme.accent : theme.sidebarSecondaryText(contrast).opacity(contrast == .increased ? 1 : 0.60))
                            .overlay {
                                if contrast == .increased { Circle().strokeBorder(theme.text, lineWidth: 1) }
                            }
                            .frame(width: selected ? 8 : 6, height: selected ? 8 : 6)
                            .frame(width: ProfileDotsScrollMetrics.itemWidth, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusable().focused($utilityFocus, equals: profile.id.uuidString)
                    .help(profile.name)
                    .accessibilityLabel("Profile \(index + 1) of \(available.count): \(profile.name)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .browserGeometryMarker("sidebarProfileDot-\(index)")
                }
            }.frame(maxWidth: .infinity)
        }
        .frame(height: 20)
        .browserGeometryMarker("sidebarProfileDotsGeometry")
    }

    @ViewBuilder private var footer: some View {
        if railLayout {
            VStack(alignment: .leading, spacing: 6) { footerButtons }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MacBrowserLayout.railInset).foregroundStyle(theme.sidebarSecondaryText(contrast))
                .browserGeometryMarker("sidebarFooterGeometry")
        } else {
            HStack(spacing: 0) { footerButtons }.padding(.horizontal, 8).frame(height: 42)
                .background(theme.surface, in: .rect(cornerRadius: OrivRadius.medium))
                .overlay { RoundedRectangle(cornerRadius: OrivRadius.medium).strokeBorder(theme.separator, lineWidth: 0.5) }
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
                    if peeking { Text(section.title).font(OrivType.body).modifier(SidebarLabelFade()); Spacer() }
                }
            }.orivButton(.quiet).foregroundStyle(theme.sidebarSecondaryText(contrast))
                .focused($utilityFocus, equals: section.rawValue)
                .accessibilityLabel(section == .downloads && controller.downloads.hasActiveDownloads ? "Downloads in progress" : section.title)
                .help(section.title).browserGeometryMarker("sidebarFooter-\(section.rawValue)")
        }
        if !railLayout { Spacer(minLength: 0) }
        SettingsLink {
            HStack(spacing: 8) {
                Image(systemName: "gearshape").font(.system(size: 16)).frame(width: railLayout ? 42 : 32, height: railLayout ? 36 : 32)
                if peeking { Text("Settings").font(OrivType.body).modifier(SidebarLabelFade()); Spacer() }
            }
        }
            .orivButton(.quiet).foregroundStyle(theme.sidebarSecondaryText(contrast)).accessibilityLabel("Settings").help("Settings (⌘,)")
            .focused($utilityFocus, equals: "settings")
            .browserGeometryMarker("sidebarFooter-Settings")
    }
}

private enum ProfileDotsScrollMetrics {
    static let itemWidth: CGFloat = 24
}

/// Hosts the existing dot buttons in a scroll view with the same gesture
/// delivery as the tab list, while keeping horizontal overflow scrollable.
private struct ProfileDotsScroll<Content: View>: NSViewRepresentable {
    let profiles: BrowserProfiles
    let count: Int
    let indexToCenter: Int
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> DotScrollView {
        let scroll = DotScrollView()
        scroll.drawsBackground = false
        scroll.setAccessibilityLabel("Profiles")
        scroll.automaticallyAdjustsContentInsets = false
        scroll.verticalScrollElasticity = .none
        let hosted = NSHostingView(rootView: AnyView(content.environment(\.self, context.environment)))
        hosted.sizingOptions = []
        scroll.documentView = hosted
        return scroll
    }

    func updateNSView(_ scroll: DotScrollView, context: Context) {
        scroll.profiles = profiles
        let hosted = scroll.documentView as? NSHostingView<AnyView>
        hosted?.rootView = AnyView(content.environment(\.self, context.environment))
        let visualIndex = context.environment.layoutDirection == .rightToLeft ? count - 1 - indexToCenter : indexToCenter
        scroll.configure(count: count, visualIndex: visualIndex)
    }

    final class DotScrollView: ProfileSidebarScrollView {
        private var count = 0
        private var visualIndex = 0
        private var viewportWidth: CGFloat = 0
        private var recenter = true

        func configure(count: Int, visualIndex: Int) {
            guard self.count != count || self.visualIndex != visualIndex else { return }
            self.count = count
            self.visualIndex = visualIndex
            recenter = true
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let visible = contentView.bounds.size
            guard visible.width > 0, let documentView else { return }
            let itemWidth = ProfileDotsScrollMetrics.itemWidth
            let width = max(visible.width, CGFloat(count) * itemWidth)
            documentView.setFrameSize(NSSize(width: width, height: visible.height))
            if recenter || viewportWidth != visible.width {
                recenter = false
                viewportWidth = visible.width
                let center = (CGFloat(visualIndex) + 0.5) * itemWidth
                let offset = min(max(0, center - visible.width / 2), width - visible.width)
                contentView.scroll(to: NSPoint(x: offset, y: 0))
                reflectScrolledClipView(contentView)
            }
        }
    }
}

struct SidebarSectionHeading: View {
    @Environment(\.sidebarContrast) private var contrast
    @Environment(\.browserTheme) private var theme
    let title: String
    let count: Int
    var marksGeometry = true
    var body: some View {
        HStack(spacing: 6) {
            if title == "Private" { Image(systemName: "eyeglasses").foregroundStyle(theme.sidebarPrivateAccent) }
            Text(title).foregroundStyle(title == "Private" ? theme.sidebarPrivateAccent : theme.sidebarSecondaryText(contrast))
            Spacer()
            if count > 0 { Text("\(count)").font(.system(size: 11)).monospacedDigit() }
        }
        .font(OrivType.title).foregroundStyle(theme.sidebarSecondaryText(contrast))
        .browserGeometryMarker("sidebarSection-\(title)", when: marksGeometry)
        .padding(.horizontal, MacBrowserLayout.sidebarRowInset).frame(height: 27)
        .padding(.top, title == "Private" ? 8 : (title == "Tabs" || title == "More pinned tabs" ? 4 : 0))
    }
}

struct SidebarTabArtwork: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.sidebarContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var textSize
    private let tab: BrowserTab?
    private let record: TabRecord?
    private let previewIsPrivate: Bool
    private let id: UUID
    private var title: String { tab?.displayTitle ?? record?.title ?? "" }
    private var url: URL? { tab?.url ?? record?.url }
    private var isPrivate: Bool { tab?.isPrivate ?? previewIsPrivate }
    let selected: Bool
    let active: Bool
    let tile: Bool
    let rail: Bool
    let peek: Bool
    let hovered: Bool
    let subtitle: String?
    var previewIcons: [String: SiteIcon]? = nil
    #if DEBUG
    @Environment(\.sidebarCaptureState) private var captureState
    #endif

    init(tab: BrowserTab, selected: Bool, active: Bool, tile: Bool, rail: Bool, peek: Bool,
         hovered: Bool, subtitle: String?) {
        self.tab = tab; id = tab.id; record = nil; previewIsPrivate = false
        self.selected = selected; self.active = active; self.tile = tile; self.rail = rail
        self.peek = peek; self.hovered = hovered; self.subtitle = subtitle
    }

    init(record: TabRecord, selected: Bool, tile: Bool, subtitle: String?, icons: [String: SiteIcon],
         isPrivate: Bool = false) {
        tab = nil; id = record.id; self.record = record; previewIsPrivate = isPrivate
        self.selected = selected; active = selected; self.tile = tile; self.subtitle = subtitle
        rail = false; peek = false; hovered = false
        previewIcons = icons
    }

    private var loading: Bool {
        guard let tab else { return false }
        #if DEBUG
        return tab.isLoading || captureState.loading == tab.id
        #else
        return tab.isLoading
        #endif
    }

    private var mediaSymbol: String? {
        guard let tab else { return nil }
        if tab.mediaSuspended { return "pause.circle" }
        if tab.isAudioMuted { return "speaker.slash.fill" }
        #if DEBUG
        if captureState.audio == tab.id { return "speaker.wave.2.fill" }
        #endif
        return tab.isPlayingAudio ? "speaker.wave.2.fill" : nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if rail {
                favicon.frame(width: 42, height: 36)
                    .overlay(alignment: .bottomTrailing) {
                        if let mediaSymbol { badge(mediaSymbol) }
                    }
                    .overlay(alignment: .topTrailing) { if isPrivate { badge("eyeglasses") } }
                if peek { Text(title).font(OrivType.body).lineLimit(1); Spacer(minLength: 0) }
            } else {
                favicon
                if !tile {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.system(size: textSize.isAccessibilitySize ? 26 : 13, weight: active ? .medium : .regular))
                            .lineLimit(subtitle == nil && textSize.isAccessibilitySize ? 2 : 1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: textSize.isAccessibilitySize ? 17 : 11))
                                .foregroundStyle(theme.sidebarSecondaryText(contrast))
                                .lineLimit(1).truncationMode(.middle)
                                .browserGeometryMarker("sidebarHost-\(id)", when: previewIcons == nil)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let mediaSymbol {
                        Image(systemName: mediaSymbol)
                            .font(.system(size: 11)).foregroundStyle(theme.sidebarSecondaryText(contrast))
                            .frame(width: 24, height: 24).padding(.leading, -8)
                            .browserGeometryMarker("sidebarMedia-\(id)")
                    }
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.sidebarSecondaryText(contrast)).frame(width: 24, height: 24).padding(.leading, -8)
                        .opacity(hovered || selected || active ? 1 : 0)
                        .browserGeometryMarker("sidebarClose-\(id)", when: previewIcons == nil)
                }
            }
        }
        .padding(.horizontal, rail || tile ? 0 : MacBrowserLayout.sidebarRowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.text)
        .background(selected ? theme.sidebar.selection : (hovered ? theme.sidebar.hover : (tile && !rail ? theme.sidebar.field.opacity(0.6) : .clear)),
                    in: .rect(cornerRadius: radius))
        .browserGeometryMarker("sidebarSelection-\(id)", when: active && previewIcons == nil)
        .overlay(alignment: .leading) {
            if active { SelectionMarker(height: 16, background: theme.sidebar.selection).browserGeometryMarker("sidebarAccent-\(id)", when: previewIcons == nil).padding(.leading, 1) }
        }
        .overlay {
            if selected && contrast == .increased {
                RoundedRectangle(cornerRadius: radius).strokeBorder(theme.text, lineWidth: 2)
            }
        }
    }

    private var radius: CGFloat { rail || tile ? OrivRadius.medium : OrivRadius.small }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 12, height: 12)
            .foregroundStyle(symbol == "eyeglasses" ? theme.sidebarPrivateAccent : theme.text)
            .background(theme.surface, in: Circle())
    }

    private var favicon: some View {
        let size: CGFloat = rail ? 22 : (tile ? 24 : 19)
        return ZStack {
            SiteIdentity(url: url, size: size, isPrivate: isPrivate, isSelected: active, sidebarIcon: true, previewIcons: previewIcons)
                .browserGeometryMarker("sidebarFavicon-\(id)", when: previewIcons == nil)
            if loading {
                Circle().trim(from: 0, to: 0.75).stroke(theme.accent, lineWidth: 2)
                    .frame(width: rail ? 26 : 24, height: rail ? 26 : 24)
            }
        }.frame(width: size, height: size)
    }
}

#if DEBUG
struct SidebarCaptureState {
    var hover: UUID? = nil
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

enum SidebarColor: String, CaseIterable {
    case graphite, profile, rose, peach, butter, mint, sage, sky, lavender

    static let preferenceKey = "SidebarColor"

    var title: String { self == .profile ? OrivStrings.profileColor : rawValue.capitalized }

    static func saved(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .graphite
    }

    func effective(profileColor: ProfileColor?, isT3Code: Bool) -> Self {
        profileColor == nil || isT3Code ? .graphite : self
    }

    func backing(in theme: Theme, profileColor: ProfileColor?) -> Color {
        switch effective(profileColor: profileColor, isT3Code: theme.isT3Code) {
        case .graphite: theme.sidebar.backing
        case .profile: profileColor?.sidebarBacking ?? theme.sidebar.backing
        case .rose: Self.roseBacking
        case .peach: Self.peachBacking
        case .butter: Self.butterBacking
        case .mint: Self.mintBacking
        case .sage: Self.sageBacking
        case .sky: Self.skyBacking
        case .lavender: Self.lavenderBacking
        }
    }

    private static let roseBacking = Theme.adaptive("SidebarRose", light: 0xF6DCE5, dark: 0x492736)
    private static let peachBacking = Theme.adaptive("SidebarPeach", light: 0xF8E1D4, dark: 0x4C2E27)
    private static let butterBacking = Theme.adaptive("SidebarButter", light: 0xF7EDC5, dark: 0x42351D)
    private static let mintBacking = Theme.adaptive("SidebarMint", light: 0xD8EFE3, dark: 0x173B30)
    private static let sageBacking = Theme.adaptive("SidebarSage", light: 0xDDE8CD, dark: 0x303A24)
    private static let skyBacking = Theme.adaptive("SidebarSky", light: 0xD6E9F8, dark: 0x21364A)
    private static let lavenderBacking = Theme.adaptive("SidebarLavender", light: 0xE6DDF7, dark: 0x39284D)
}

private extension ProfileColor {
    var sidebarBacking: Color {
        switch self {
        case .mulberry: Self.mulberryBacking
        case .ocean: Self.oceanBacking
        case .fern: Self.fernBacking
        case .amber: Self.amberBacking
        case .slate: Self.slateBacking
        }
    }

    private static let mulberryBacking = Theme.adaptive("SidebarMulberry", light: 0xF1DBEE, dark: 0x45243F)
    private static let oceanBacking = Theme.adaptive("SidebarOcean", light: 0xCFEAF8, dark: 0x1C344D)
    private static let fernBacking = Theme.adaptive("SidebarFern", light: 0xD7EED5, dark: 0x233A25)
    private static let amberBacking = Theme.adaptive("SidebarAmber", light: 0xFAE7CC, dark: 0x493223)
    private static let slateBacking = Theme.adaptive("SidebarSlate", light: 0xDFE7F2, dark: 0x2A3544)
}

enum SidebarGlassOpacity: String, CaseIterable {
    case balanced = "Balanced"
    case high = "High"
    case solid = "Solid"

    static let preferenceKey = "SidebarGlassOpacity"

    var backingOpacity: Double {
        switch self {
        case .balanced: 0.55
        case .high: 0.80
        case .solid: 1.0
        }
    }
}

/// A single system glass surface, never one effect per tab. A contrast backing
/// above the glass bounds even its brightest/darkest sampled pixels, so theme
/// text cannot become white-on-light-grey when the page and system differ.
/// check-contrast.py reads these constants to test the composited backgrounds.
struct MacSidebarGlass: ViewModifier {
    var color: SidebarColor = .graphite
    var profileColor: ProfileColor? = nil

    // A neutral guard bounds the luma of the exposed glass. Dark profile
    // colors need more protection against bright page input than Black.
    private static let balancedTintGuard = Theme.adaptive("SidebarTintGuard", light: 0xFFFFFF, dark: 0x000000)
    private static let balancedLightGuard = 0.26
    private static let balancedLightTintGuard = 0.32
    private static let balancedDarkGuard = 0.30
    private static let balancedDarkTintGuard = 0.38
    private static let balancedBlackGuard = 0.18

    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(SidebarGlassOpacity.preferenceKey) private var opacity: SidebarGlassOpacity = .balanced
    #if DEBUG
    @Environment(\.sidebarCaptureOpacity) private var captureOpacity
    #endif
    private var effectiveOpacity: SidebarGlassOpacity {
        #if DEBUG
        captureOpacity ?? opacity
        #else
        opacity
        #endif
    }
    @Environment(\.browserTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    @Environment(\.sidebarContrast) private var contrast
    #if DEBUG
    @Environment(\.sidebarCaptureBackdrop) private var captureBackdrop
    #endif
    func body(content: Content) -> some View {
        let backing = color.backing(in: theme, profileColor: profileColor)
        if reduceTransparency || captureReduceTransparency || contrast == .increased || effectiveOpacity == .solid {
            edge(content.background(backing))
        } else {
            let tinted = color.effective(profileColor: profileColor, isT3Code: theme.isT3Code) != .graphite
            let guardOpacity = effectiveOpacity == .balanced ? balancedGuard(tinted: tinted) : 0
            edge(glass(content.background(backing.opacity(effectiveOpacity.backingOpacity))
                .background(Self.balancedTintGuard.opacity(guardOpacity))))
        }
    }
    private func balancedGuard(tinted: Bool) -> Double {
        if theme.isT3Code { return Self.balancedBlackGuard }
        if colorScheme == .dark { return tinted ? Self.balancedDarkTintGuard : Self.balancedDarkGuard }
        return tinted ? Self.balancedLightTintGuard : Self.balancedLightGuard
    }
    private func edge<Surface: View>(_ content: Surface) -> some View {
        content.overlay(alignment: .trailing) {
            Canvas { context, size in
                let color = contrast == .increased ? theme.text : theme.separator.opacity(0.5)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color))
            }
            .frame(width: contrast == .increased ? 1.5 : 0.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
    @ViewBuilder private func glass<Surface: View>(_ content: Surface) -> some View {
        #if DEBUG
        if let captureBackdrop {
            content.background(captureBackdrop)
        } else {
            GlassEffectContainer { content.glassEffect(.clear, in: Rectangle()) }
        }
        #else
        GlassEffectContainer { content.glassEffect(.clear, in: Rectangle()) }
        #endif
    }
}

#if DEBUG
extension EnvironmentValues {
    @Entry var sidebarCaptureOpacity: SidebarGlassOpacity? = nil
}
#endif
