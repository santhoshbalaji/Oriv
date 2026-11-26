import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI

/// A drag is scoped to this controller, so another profile/window cannot move it.
struct SidebarTabTransfer: Codable {
    let id: UUID
    let owner: UUID
}

enum SidebarDropTarget: Equatable { case tab(UUID), between(UUID, after: Bool), pinned(Bool, isPrivate: Bool = false) }
enum SidebarTabCommand { case pin, duplicate, moveUp, moveDown, reload, copyLink, mute, media, close, newPrivate }

/// SwiftUI focus can use a window-sized AppKit responder. Publish ownership
/// separately so collapse can hand focus to its surviving toggle in this window.
struct SidebarKeyboardFocusKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct SidebarTabQuery: Equatable {
    let text: String
    let isPrivate: Bool

    init(text: String, isPrivate: Bool) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        self.isPrivate = isPrivate
    }

    @MainActor func matches(_ tab: BrowserTab) -> Bool {
        isPrivate == tab.isPrivate && (text.isEmpty || [tab.displayTitle, tab.hostname].contains {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(text)
        })
    }
}

struct SidebarSearchScope: View {
    @Bindable var controller: BrowserController
    var body: some View {
        if controller.tabSearchHasBothScopes {
            Picker("Search scope", selection: Binding(
                get: { controller.tabSearchIsPrivate },
                set: { controller.tabSearchPrivacyOverride = $0 }
            )) {
                Text("Tabs").tag(false)
                Text("Private").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
        }
    }
}

/// Shared by the real drop targets and their tests. Cross-section drops are
/// explicit on headings; a row drop never silently changes privacy or pin state.
@MainActor enum SidebarTabs {
    struct PinGrid {
        let columns: Int
        let tileWidth: CGFloat

        init(availableWidth: CGFloat) {
            let gap = OrivMacV3.SidebarLayout.pinGap
            let minWidth = OrivMacV3.SidebarLayout.pinMinWidth
            columns = min(OrivMacV3.SidebarLayout.pinMaxColumns,
                          max(OrivMacV3.SidebarLayout.pinColumns, Int((availableWidth + gap) / (minWidth + gap))))
            tileWidth = max(0, (availableWidth - CGFloat(columns - 1) * gap) / CGFloat(columns))
        }
    }

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
        guard controller.session.isProfileActive, item.owner == controller.sidebarDragID,
              let source = controller.session.tabs.first(where: { $0.id == item.id }) else { return false }
        switch target {
        case .pinned(_, let isPrivate): return source.isPrivate == isPrivate
        case .tab(let id):
            guard let destination = controller.session.tabs.first(where: { $0.id == id }) else { return false }
            return source.id != id && source.isPrivate == destination.isPrivate && source.isPinned == destination.isPinned
        case .between(let id, _):
            guard let destination = controller.session.tabs.first(where: { $0.id == id }) else { return false }
            return source.id != id && source.isPrivate == destination.isPrivate
        }
    }

    static func drop(_ items: [SidebarTabTransfer], on target: SidebarDropTarget, controller: BrowserController) -> Bool {
        guard items.count == 1, let item = items.first, canDrop(item, on: target, controller: controller) else { return false }
        switch target {
        case .pinned(let pinned, _): controller.session.placeSidebarTab(item.id, pinned: pinned)
        case .tab(let id): controller.session.moveTab(item.id, to: id)
        case .between(let id, let after):
            guard let destination = controller.session.tabs.first(where: { $0.id == id }) else { return false }
            controller.session.placeSidebarTab(item.id, pinned: destination.isPinned, relativeTo: id, after: after)
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.v3AppearanceMode) private var v3Mode
    @Environment(\.dynamicTypeSize) private var textSize
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
    private var mode: OrivMacV3.AppearanceMode {
        OrivMacV3.AppearanceMode.resolve(theme: theme, colorScheme: scheme, isPrivateWindow: privateWindow || v3Mode == .private)
    }

    var body: some View {
        let request = !compact && (searchFocused || controller.tabSearchIsFiltering) ? controller.tabSearchRequest : nil
        let tabs = request.map(controller.tabSearchResults) ?? session.orderedTabs
        let secondary = OrivMacV3.Ink.secondary(mode, increasedContrast: contrast == .increased)
        return VStack(spacing: railLayout ? OrivMacV3.SidebarLayout.pinGap : .zero) {
            VStack(spacing: railLayout ? OrivMacV3.SidebarLayout.pinGap : .zero) {
                profileHeader
                searchField(firstResult: request == nil ? nil : tabs.first?.id)
                if !railLayout && (searchFocused || request != nil) {
                    SidebarSearchScope(controller: controller).padding(.bottom, OrivSpacing.small)
                }
                if railLayout { newTab }
                if let notice = profiles?.notice, !session.isExternalPrivate, !compact {
                    Text(notice).font(OrivType.caption).foregroundStyle(secondary).padding(.horizontal, OrivSpacing.large)
                }
                tabArea(tabs: tabs, request: request)
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
        .padding(.horizontal, railLayout ? .zero : MacBrowserLayout.sidebarInset)
        .padding(.bottom, railLayout ? .zero : MacBrowserLayout.sidebarInset)
        .background {
            if !railLayout, let profiles, profiles.canSwitchProfiles(from: controller) {
                ProfileSidebarSwipeRegion(switcher: profiles.sidebarSwitch, controller: controller, kind: .sidebar)
            }
        }
        .font(OrivType.body)
        .foregroundStyle(OrivMacV3.Ink.primary(mode))
        .transformPreference(SidebarKeyboardFocusKey.self) { $0 = $0 || searchFocused || utilityFocus != nil || tabList.hasFocus }
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
            if let id, controller.tabSearchIsFiltering,
               !controller.tabSearchResults(controller.tabSearchRequest).contains(where: { $0.id == id }) {
                controller.dismissTabSearch()
            }
        }
        .confirmationDialog(controller.profileUI.closeToRight ? "Close tabs to the right?" : "Close other tabs?", isPresented: Binding(get: { controller.profileUI.closeOthers != nil }, set: { if !$0 { controller.profileUI.closeOthers = nil } })) {
            Button("Close Tabs", role: .destructive) { if let id = controller.profileUI.closeOthers { session.closeOtherTabs(id, toRight: controller.profileUI.closeToRight) }; controller.profileUI.closeOthers = nil }
        } message: { Text("Pinned tabs and tabs in the other privacy group stay open. Unsaved website forms in closed tabs may be lost.") }
    }

    private func tabArea(tabs: [BrowserTab], request: ProfileScoped<SidebarTabQuery>?) -> some View {
        GeometryReader { proxy in
            let newTabGap = OrivMacV3.SidebarLayout.newTabTopMargin - OrivMacV3.SidebarLayout.tabRowGap
            let newTabBlock = newTabGap + OrivMacV3.SidebarLayout.newTabHeight + MacBrowserLayout.sidebarFooterGap
            let availableList = max(.zero, proxy.size.height - newTabBlock)
            let estimated = estimatedTabListHeight(tabs: tabs, searching: request != nil, width: proxy.size.width)
            let _ = { tabList.fallbackHeight = estimated }()
            let measured = tabList.contentHeight ?? estimated
            let overflowing = !railLayout && measured > availableList + OrivOutline.hairline
            let listHeight = railLayout ? proxy.size.height : min(measured, availableList)
            VStack(spacing: .zero) {
                NativeSidebarTabs(controller: controller, profiles: profiles, handle: tabList, tabs: tabs,
                                  duplicateTitles: SidebarTabs.duplicateTitles(in: tabs), rail: compact, peek: peeking,
                                  expandedWidth: controller.sidebar.expandedWidth, overflowing: overflowing,
                                  searchRequest: request) { id, right in
                    controller.profileUI.closeToRight = right
                    controller.profileUI.closeOthers = id
                }
                .frame(height: listHeight)
                if !railLayout {
                    newTab
                        .padding(.top, newTabGap)
                        .padding(.bottom, MacBrowserLayout.sidebarFooterGap)
                        .overlay(alignment: .top) {
                            if overflowing {
                                Rectangle()
                                    .fill(OrivMacV3.Sidebar.footerSeparator(mode, increasedContrast: contrast == .increased))
                                    .frame(height: contrast == .increased ? OrivOutline.enhanced : OrivOutline.hairline)
                                    .accessibilityHidden(true)
                            }
                        }
                    Spacer(minLength: .zero)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    private func estimatedTabListHeight(tabs: [BrowserTab], searching: Bool, width: CGFloat) -> CGFloat {
        let rowHeight = textSize.isAccessibilitySize ? OrivLayout.sidebarAccessibilityRowHeight : OrivMacV3.SidebarLayout.tabRowHeight
        let rowPitch = rowHeight + OrivMacV3.SidebarLayout.tabRowGap
        if tabs.isEmpty { return OrivMacV3.SidebarLayout.pinHeight }
        let pins = tabs.filter(\.isPinned)
        let regular = tabs.filter { !$0.isPinned && !$0.isPrivate }
        let privateTabs = tabs.filter { $0.isPrivate && !$0.isPinned }
        var height: CGFloat = .zero
        if !pins.isEmpty {
            height += OrivMacV3.SidebarLayout.sectionTotalHeight
            if searching {
                height += CGFloat(pins.count) * rowPitch
            } else {
                let grid = SidebarTabs.PinGrid(availableWidth: max(.zero, width))
                let rows = (pins.count + grid.columns - 1) / grid.columns
                let hasFollowing = !regular.isEmpty || !privateTabs.isEmpty
                height += CGFloat(rows) * (OrivMacV3.SidebarLayout.pinHeight + OrivMacV3.SidebarLayout.pinGap)
                    - OrivMacV3.SidebarLayout.pinGap
                    + (hasFollowing ? OrivMacV3.SidebarLayout.pinBottomMargin : OrivMacV3.SidebarLayout.tabRowGap)
            }
        }
        if !regular.isEmpty {
            height += OrivMacV3.SidebarLayout.sectionTotalHeight + CGFloat(regular.count) * rowPitch
            if !privateTabs.isEmpty { height += OrivSpacing.medium - OrivMacV3.SidebarLayout.tabRowGap }
        }
        if !privateTabs.isEmpty {
            height += OrivMacV3.SidebarLayout.sectionTotalHeight
            height += CGFloat(privateTabs.count) * rowPitch
        }
        return height
    }

    private var profileHeader: some View {
        Group {
            if let profiles, !privateWindow {
                ProfileMenu(profiles: profiles, iconOnly: railLayout, tabCount: session.tabs.count,
                            showsKeyboardFocus: controller.sidebar.showsUtilityKeyboardFocus)
            } else {
                ProfileHeaderArtwork(profile: privateWindow ? nil : controller.profile,
                                     tabCount: session.tabs.count, iconOnly: railLayout)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(privateWindow ? "Private browsing" : controller.profile?.name ?? "Personal")
                    .accessibilityValue(SidebarTabs.countLabel(session.tabs.count))
            }
        }
        .frame(maxWidth: .infinity, alignment: railLayout ? .center : .leading)
        .browserGeometryMarker("sidebarProfileGeometry")
        .padding(.trailing, profileTrailingInset)
        .padding(.top, !railLayout && profileTrailingInset > .zero ? OrivSpacing.xs : .zero)
        .padding(.bottom, railLayout ? .zero : OrivMacV3.SidebarLayout.profileBottomMargin)
    }

    @ViewBuilder private func searchField(firstResult: UUID?) -> some View {
        let request = controller.tabSearchRequest
        let secondary = OrivMacV3.Ink.secondary(mode, increasedContrast: contrast == .increased)
        let searchPlaceholder = privateWindow ? OrivStrings.searchPrivateTabs : OrivStrings.searchTabs
        if railLayout {
            Button { controller.searchTabs() } label: {
                HStack(spacing: OrivSpacing.small) {
                    Image(systemName: "magnifyingglass").frame(width: MacBrowserLayout.railItemWidth, height: MacBrowserLayout.railItemHeight)
                    if peeking { Text(searchPlaceholder).modifier(SidebarLabelFade()); Spacer() }
                }
            }.frame(width: compact ? MacBrowserLayout.railItemWidth : nil)
                .buttonStyle(SidebarToneButtonStyle()).focused($utilityFocus, equals: "search")
                .browserGeometryMarker("sidebarSearchGeometry")
                .accessibilityLabel(searchPlaceholder).help("Search Tabs (⇧⌘A)")
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                .padding(.horizontal, MacBrowserLayout.railInset)
        } else {
            OrivSearchField(text: $controller.tabSearch, shortcut: "⇧⌘A", sidebar: true,
                            focused: searchFocused, ink: secondary,
                            clearLabel: "Clear tab search", onClear: { searchFocused = true }) {
                TextField(searchPlaceholder, text: $controller.tabSearch,
                          prompt: Text(searchPlaceholder).foregroundStyle(secondary))
                    .focused($searchFocused).accessibilityLabel(searchPlaceholder).accessibilityIdentifier("tabSearchField")
                    .accessibilityHint("Press Shift-Command-A to focus \(searchPlaceholder).")
                    .onExitCommand { controller.dismissTabSearch(); focusTabAfterSearch(session.selectedTabID) }
                    .onKeyPress(.downArrow) {
                        guard request == controller.tabSearchRequest,
                              let first = controller.tabSearchResults(request).first else { return .ignored }
                        focusTabAfterSearch(first.id)
                        return .handled
                    }
                    .onSubmit {
                        guard let firstResult, controller.activateSidebarTab(firstResult, request: request) else { return }
                        focusTabAfterSearch(firstResult)
                    }
            }
            .background {
                if searchFocused, let profiles {
                    ProfileSidebarSwipeRegion(switcher: profiles.sidebarSwitch, controller: controller, kind: .editing)
                }
            }
            .browserGeometryMarker("sidebarSearchGeometry")
            .padding(.bottom, (searchFocused || controller.tabSearchIsFiltering) && controller.tabSearchHasBothScopes
                     ? OrivSpacing.xs : OrivMacV3.SidebarLayout.searchBottomMargin)
        }
    }

    private func focusTabAfterSearch(_ id: UUID?) {
        searchFocused = false
        // Let SwiftUI release the field editor before installing the native responder.
        DispatchQueue.main.async { tabList.focus(id) }
    }

    private var newTab: some View {
        let isPrivate = session.selectedTab?.isPrivate ?? session.isExternalPrivate
        let title = isPrivate ? "New Private Tab" : "New Tab"
        let secondary = OrivMacV3.Ink.secondary(mode, increasedContrast: contrast == .increased)
        let tertiary = OrivMacV3.Ink.tertiary(mode, onSidebar: true, increasedContrast: contrast == .increased)
        return Button { controller.newTab(isPrivate: isPrivate) } label: {
            HStack(spacing: railLayout ? OrivSpacing.small : OrivMacV3.SidebarLayout.tabRowInnerGap) {
                Image(systemName: "plus")
                    .font(railLayout ? OrivType.body : OrivMacV3.Typography.detailSemibold)
                    .frame(width: railLayout ? MacBrowserLayout.railItemWidth : OrivMacV3.SidebarLayout.tabFaviconSize)
                if peeking { Text(title).modifier(SidebarLabelFade()); Spacer() }
                if !railLayout {
                    Text(title)
                    Spacer(minLength: .zero)
                    Text("⌘T")
                        .font(OrivMacV3.Typography.shortcutHint)
                        .tracking(OrivMacV3.Typography.labelTracking)
                        .foregroundStyle(tertiary)
                }
            }
            .font(railLayout ? OrivType.body : OrivMacV3.Typography.sidebarNewTab)
            .foregroundStyle(railLayout ? OrivMacV3.Ink.primary(mode) : secondary)
            .padding(.horizontal, railLayout ? .zero : OrivMacV3.SidebarLayout.newTabLeadingPadding)
            .frame(maxWidth: .infinity,
                   minHeight: railLayout ? MacBrowserLayout.railItemHeight : OrivMacV3.SidebarLayout.newTabHeight,
                   maxHeight: railLayout ? MacBrowserLayout.railItemHeight : OrivMacV3.SidebarLayout.newTabHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarToneButtonStyle(radius: railLayout ? OrivMacV3.Radius.control : OrivMacV3.Radius.row))
        .frame(width: compact ? MacBrowserLayout.railItemWidth : nil)
        .padding(.horizontal, peeking ? MacBrowserLayout.railInset : .zero)
        .browserGeometryMarker("sidebarNewTabGeometry")
        .focused($utilityFocus, equals: "new-tab")
        .modifier(SidebarFocusRing(visible: utilityFocus == "new-tab" && controller.sidebar.showsUtilityKeyboardFocus,
                                   radius: railLayout ? OrivMacV3.Radius.control : OrivMacV3.Radius.row))
        .accessibilityLabel(title).accessibilityIdentifier(railLayout ? "railNewTabButton" : "newTabButton").help("\(title) (⌘T)")
    }

    private func profileDots(_ profiles: BrowserProfiles) -> some View {
        let available = profiles.available
        let centeredID = utilityFocus.flatMap(UUID.init(uuidString:)) ?? profiles.active.id
        let indexToCenter = available.firstIndex { $0.id == centeredID } ?? 0
        let increased = contrast == .increased
        return ProfileDotsScroll(profiles: profiles, count: available.count, indexToCenter: indexToCenter) {
            HStack(spacing: .zero) {
                ForEach(Array(available.enumerated()), id: \.element.id) { index, profile in
                    let selected = profile.id == profiles.active.id
                    let dotColor = OrivMacV3.Sidebar.profileDotFill(profile.color, mode: mode)
                    Button {
                        profiles.switchFromSidebar(profile.id, source: controller)
                    } label: {
                        ZStack {
                            if selected || increased {
                                Circle()
                                    .strokeBorder(OrivMacV3.Sidebar.profileDotHalo(profile.color, mode: mode, increasedContrast: increased),
                                                  lineWidth: increased ? OrivOutline.enhanced : OrivOutline.hairline * 2)
                                    .frame(width: OrivMacV3.SidebarLayout.profileDotHaloSize,
                                           height: OrivMacV3.SidebarLayout.profileDotHaloSize)
                                Circle()
                                    .fill(OrivMacV3.Sidebar.profileDotRingInner(mode))
                                    .frame(width: OrivMacV3.SidebarLayout.profileDotInnerRingSize,
                                           height: OrivMacV3.SidebarLayout.profileDotInnerRingSize)
                            }
                            Circle()
                                .fill(dotColor)
                                .opacity(selected || increased ? 1 : OrivMacV3.Sidebar.profileDotInactiveOpacity(mode))
                                .frame(width: OrivMacV3.SidebarLayout.profileDotSize, height: OrivMacV3.SidebarLayout.profileDotSize)
                        }
                        .frame(width: ProfileDotsScrollMetrics.itemWidth, height: OrivMacV3.SidebarLayout.profileDotHitTarget)
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
        .frame(height: OrivMacV3.SidebarLayout.profileDotHitTarget)
        .browserGeometryMarker("sidebarProfileDotsGeometry")
    }

    private var footer: some View {
        let increased = contrast == .increased
        return VStack(spacing: .zero) {
            Rectangle().fill(OrivMacV3.Sidebar.footerSeparator(mode, increasedContrast: increased))
                .frame(height: increased ? OrivOutline.enhanced : OrivOutline.hairline)
                .accessibilityHidden(true)
            if railLayout {
                VStack(spacing: OrivSpacing.xxs) { footerButtons }
                    .padding(.top, OrivSpacing.xs)
                    .padding(.bottom, OrivSpacing.small)
            } else {
                HStack(spacing: OrivMacV3.SidebarLayout.footerGap) { footerButtons }
                    .padding(.top, OrivMacV3.SidebarLayout.footerPaddingTop)
                    .frame(height: OrivMacV3.SidebarLayout.footerHeight - (increased ? OrivOutline.enhanced : OrivOutline.hairline),
                           alignment: .center)
            }
        }
        .padding(.horizontal, railLayout ? MacBrowserLayout.railInset : .zero)
        .foregroundStyle(OrivMacV3.Ink.secondary(mode, increasedContrast: increased))
        .browserGeometryMarker("sidebarFooterGeometry")
    }

    @ViewBuilder private var footerButtons: some View {
        ForEach(LibrarySection.allCases) { section in
            let activeDownload = section == .downloads && controller.downloads.hasActiveDownloads
            Button { controller.library = section } label: {
                footerLabel(section.title, symbol: section.symbol, activeDownload: activeDownload)
            }
            .buttonStyle(SidebarToneButtonStyle())
            .focused($utilityFocus, equals: section.rawValue)
            .modifier(SidebarFocusRing(visible: utilityFocus == section.rawValue && controller.sidebar.showsUtilityKeyboardFocus))
            .accessibilityLabel(activeDownload ? "Downloads in progress" : section.title)
            .help(section.title)
            .browserGeometryMarker("sidebarFooter-\(section.rawValue)")
        }
        if !railLayout { Spacer(minLength: .zero) }
        SettingsLink { footerLabel("Settings", symbol: "gearshape") }
            .buttonStyle(SidebarToneButtonStyle())
            .focused($utilityFocus, equals: "settings")
            .modifier(SidebarFocusRing(visible: utilityFocus == "settings" && controller.sidebar.showsUtilityKeyboardFocus))
            .accessibilityLabel("Settings").help("Settings (⌘,)")
            .browserGeometryMarker("sidebarFooter-Settings")
    }

    private func footerLabel(_ title: String, symbol: String, activeDownload: Bool = false) -> some View {
        HStack(spacing: OrivSpacing.small) {
            Image(systemName: symbol).font(.system(size: OrivMacV3.SidebarLayout.footerIconSize))
                .frame(width: railLayout ? MacBrowserLayout.railItemWidth : OrivMacV3.SidebarLayout.footerButtonSize,
                       height: railLayout ? MacBrowserLayout.railItemHeight : OrivMacV3.SidebarLayout.footerButtonSize)
                .overlay(alignment: .topTrailing) {
                    if activeDownload {
                        Circle()
                            .fill(OrivMacV3.Semantic.accent(mode))
                            .overlay {
                                Circle().stroke(OrivMacV3.Sidebar.downloadDotRing(mode),
                                                lineWidth: OrivMacV3.SidebarLayout.downloadDotRingWidth)
                            }
                            .frame(width: OrivMacV3.SidebarLayout.downloadDotSize, height: OrivMacV3.SidebarLayout.downloadDotSize)
                            .padding(OrivMacV3.SidebarLayout.downloadDotInset)
                            .accessibilityHidden(true)
                    }
                }
            if peeking { Text(title).modifier(SidebarLabelFade()); Spacer(minLength: .zero) }
        }
        .contentShape(Rectangle())
    }

}

private enum ProfileDotsScrollMetrics {
    static let itemWidth = OrivMacV3.SidebarLayout.profileDotItemWidth
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.v3AppearanceMode) private var v3Mode
    let title: String
    let count: Int
    var marksGeometry = true
    var body: some View {
        let mode = OrivMacV3.AppearanceMode.resolve(theme: theme, colorScheme: scheme,
                                                    isPrivateWindow: v3Mode == .private)
        let increased = contrast == .increased
        let privateHeader = title == "Private" && mode == .private
        SectionHeader(title: title, kind: .sidebar, count: count,
                      symbol: title == "Private" ? "eyeglasses" : nil,
                      symbolInk: OrivMacV3.Semantic.privateAccent(mode, increasedContrast: increased),
                      ink: privateHeader
                        ? OrivMacV3.Semantic.privateAccent(mode, increasedContrast: increased)
                        : OrivMacV3.Ink.secondary(mode, increasedContrast: increased),
                      countInk: OrivMacV3.Ink.tertiary(mode, onSidebar: true, increasedContrast: increased))
        .browserGeometryMarker("sidebarSection-\(title)", when: marksGeometry)
        .padding(.horizontal, OrivMacV3.SidebarLayout.sectionPaddingHorizontal)
        .frame(height: OrivMacV3.SidebarLayout.sectionHeight)
        .padding(.bottom, OrivMacV3.SidebarLayout.sectionBottomMargin)
    }
}

struct SidebarToneSurface: ViewModifier {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.self) private var environment
    @Environment(\.sidebarContrast) private var contrast
    @Environment(\.v3AppearanceMode) private var v3Mode
    let tone: Theme.SidebarTone?
    var radius: CGFloat? = nil
    var drawsRim = true

    func body(content: Content) -> some View {
        let opaque = environment.sidebarChromaticStyle?.opaque ?? environment.sidebarNeedsOpaqueChrome
        let dark = scheme == .dark
        let increased = contrast == .increased
        let mode = OrivMacV3.AppearanceMode.resolve(theme: theme, colorScheme: scheme,
                                                    isPrivateWindow: v3Mode == .private)
        let effectiveRadius = radius ?? (tone == .search ? OrivMacV3.Radius.sidebarSearch : OrivMacV3.Radius.control)
        let shape = RoundedRectangle(cornerRadius: effectiveRadius, style: .continuous)
        content.background {
            if let tone {
                switch tone {
                case .search:
                    shape.fill(OrivMacV3.Sidebar.searchFill(mode, solid: mode == .black))
                        .overlay {
                            if drawsRim && !increased {
                                shape.strokeBorder(OrivMacV3.Sidebar.searchInnerRim(mode), lineWidth: OrivOutline.hairline)
                            }
                        }
                case .hover:
                    shape.fill(OrivMacV3.Sidebar.rowHover(mode, solid: mode == .black))
                        .overlay {
                            if drawsRim && increased {
                                shape.strokeBorder(OrivMacV3.Card.rimIncreasedContrast(mode), lineWidth: OrivOutline.enhanced)
                            }
                        }
                case .selection:
                    shape.fill(tone.fill(in: theme, dark: dark, opaque: opaque))
                        .overlay {
                            if drawsRim {
                                shape.strokeBorder(theme.sidebarRim(dark: dark, opaque: opaque),
                                                   lineWidth: increased ? OrivOutline.enhanced : OrivOutline.hairline)
                            }
                        }
                }
            }
        }
    }
}

struct SidebarSelectionSurface: ViewModifier {
    let active: Bool
    let radius: CGFloat
    var drawsGlow = true
    @Environment(\.self) private var environment
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.v3AppearanceMode) private var v3Mode

    func body(content: Content) -> some View {
        content.background {
            if active {
                let style = environment.sidebarStyle
                let mode = OrivMacV3.AppearanceMode.resolve(theme: theme, colorScheme: scheme,
                                                            isPrivateWindow: v3Mode == .private)
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                let useV3Neutral = mode == .private || mode == .black || style.isGraphite
                if useV3Neutral {
                    let pill = shape
                        .fill(OrivMacV3.Sidebar.activeFill(mode, solid: style.opaque))
                        .overlay {
                            if !style.increased, let specular = OrivMacV3.Sidebar.activeTopHighlight(mode) {
                                shape.inset(by: OrivOutline.hairline)
                                    .stroke(
                                        LinearGradient(colors: [specular, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25)),
                                        lineWidth: OrivOutline.hairline * 2
                                    )
                            }
                        }
                        .overlay {
                            shape.strokeBorder(
                                OrivMacV3.Sidebar.activeBorder(mode, increasedContrast: style.increased),
                                lineWidth: style.increased ? OrivOutline.focus : OrivOutline.hairline
                            )
                        }
                    if drawsGlow && !style.opaque {
                        pill.orivV3Shadow(OrivMacV3.Sidebar.activeShadow(mode))
                    } else {
                        pill
                    }
                } else if style.opaque {
                    shape.fill(style.fill).overlay {
                        shape.strokeBorder(style.increased ? style.ink : style.rimBottom,
                                           lineWidth: style.increased ? OrivOutline.focus : OrivOutline.hairline)
                    }
                } else {
                    let fill = shape.fill(style.fill).overlay {
                        shape.strokeBorder(
                            LinearGradient(colors: [style.rimTop, style.rimBottom], startPoint: .top, endPoint: .bottom),
                            lineWidth: SidebarChromaticStyle.selectionRim)
                    }
                    if drawsGlow { style.selectionGlow(fill) } else { fill }
                }
            }
        }
    }
}

struct SidebarToneButtonStyle: ButtonStyle {
    var active = false
    var radius: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, active: active, radius: radius)
    }

    private struct Face: View {
        let configuration: Configuration
        let active: Bool
        let radius: CGFloat?
        @State private var hovered = false

        var body: some View {
            configuration.label
                .environment(\.sidebarRowHovered, !active && hovered)
                .modifier(SidebarToneSurface(tone: active ? nil : configuration.isPressed ? .selection : hovered ? .hover : nil,
                                             radius: radius))
                .onHover { hovered = $0 }
        }
    }
}

struct SidebarFocusRing: ViewModifier {
    var visible: Bool
    var radius: CGFloat = OrivMacV3.Radius.control

    func body(content: Content) -> some View {
        content.focusEffectDisabled().overlay {
            if visible {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.sidebarKeyboardFocus, lineWidth: OrivOutline.focus)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

enum SidebarRowAccessory { case close, audio }

struct SidebarTabArtwork: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.sidebarContrast) private var contrast
    @Environment(\.self) private var environment
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
    var hoveredAccessory: SidebarRowAccessory?
    let subtitle: String?
    var previewIcons: [String: SiteIcon]? = nil
    var drawsSelectionGlow = true
    var resolvedStyle: SidebarChromaticStyle? = nil
    var resolvedMode: OrivMacV3.AppearanceMode? = nil
    #if DEBUG
    @Environment(\.sidebarCaptureState) private var captureState
    #endif

    init(tab: BrowserTab, selected: Bool, active: Bool, tile: Bool, rail: Bool, peek: Bool,
         hovered: Bool, hoveredAccessory: SidebarRowAccessory? = nil, subtitle: String?,
         resolvedStyle: SidebarChromaticStyle? = nil, resolvedMode: OrivMacV3.AppearanceMode? = nil) {
        self.tab = tab; id = tab.id; record = nil; previewIsPrivate = false
        self.selected = selected; self.active = active; self.tile = tile; self.rail = rail
        self.peek = peek; self.hovered = hovered; self.hoveredAccessory = hoveredAccessory; self.subtitle = subtitle
        self.resolvedStyle = resolvedStyle; self.resolvedMode = resolvedMode
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
        let style = resolvedStyle ?? environment.sidebarStyle
        let mode = resolvedMode ?? OrivMacV3.AppearanceMode.resolve(theme: theme, colorScheme: environment.colorScheme,
                                                                    isPrivateWindow: environment.v3AppearanceMode == .private)
        let selectedInk = active ? style.v3ActiveInk(mode: mode) : nil
        let primaryInk = OrivMacV3.Ink.primary(mode)
        let secondaryInk = OrivMacV3.Ink.secondary(mode, increasedContrast: style.increased)
        let showsClose = hovered || selected || active
        return HStack(spacing: rail ? OrivSpacing.small : OrivMacV3.SidebarLayout.tabRowInnerGap) {
            if rail {
                favicon(mode: mode, style: style, selectedInk: selectedInk).frame(width: MacBrowserLayout.railItemWidth, height: MacBrowserLayout.railItemHeight)
                    .overlay(alignment: .bottomTrailing) {
                        if let mediaSymbol { badge(mediaSymbol) }
                    }
                if peek {
                    Text(title)
                        .font(active ? OrivMacV3.Typography.sidebarRowActive : OrivMacV3.Typography.sidebarRow)
                        .tracking(active ? OrivMacV3.Typography.tightTracking : .zero)
                        .lineLimit(1)
                    Spacer(minLength: .zero)
                }
            } else if tile {
                favicon(mode: mode, style: style, selectedInk: selectedInk)
            } else {
                favicon(mode: mode, style: style, selectedInk: selectedInk)
                VStack(alignment: .leading, spacing: .zero) {
                    Text(title)
                        .font(textSize.isAccessibilitySize ? .system(size: 26, weight: active ? .semibold : .regular)
                              : (active ? OrivMacV3.Typography.sidebarRowActive : OrivMacV3.Typography.sidebarRow))
                        .tracking(!textSize.isAccessibilitySize && active ? OrivMacV3.Typography.tightTracking : .zero)
                        .foregroundStyle(selectedInk ?? (loading ? secondaryInk : primaryInk))
                        .lineLimit(subtitle == nil && textSize.isAccessibilitySize ? 2 : 1)
                    if let subtitle {
                        Text(subtitle)
                            .font(textSize.isAccessibilitySize ? OrivType.windowTitle : OrivType.caption)
                            .foregroundStyle(selectedInk ?? secondaryInk)
                            .lineLimit(1).truncationMode(.middle)
                            .browserGeometryMarker("sidebarHost-\(id)", when: previewIcons == nil)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if mediaSymbol != nil || showsClose {
                    HStack(spacing: OrivSpacing.xxs) {
                        if let mediaSymbol {
                            accessory(mediaSymbol, kind: .audio, ink: selectedInk ?? OrivMacV3.Sidebar.audioInk(mode))
                                .browserGeometryMarker("sidebarMedia-\(id)", when: previewIcons == nil)
                        }
                        if showsClose {
                            accessory("xmark", kind: .close,
                                      ink: (selectedInk ?? secondaryInk)
                                        .opacity(OrivMacV3.Sidebar.closeAccessoryOpacity(mode, active: active, increasedContrast: style.increased)))
                                .browserGeometryMarker("sidebarClose-\(id)", when: previewIcons == nil)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, rail ? .zero : OrivMacV3.SidebarLayout.tabRowPaddingHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(selectedInk ?? primaryInk)
        .background {
            if active {
                Rectangle().opacity(0)
                    .modifier(SidebarSelectionSurface(active: active, radius: radius, drawsGlow: drawsSelectionGlow))
                    .environment(\.sidebarChromaticStyle, style)
            } else if tile {
                pinTileSurface(mode: mode, style: style)
            } else if hovered {
                Rectangle().opacity(0)
                    .modifier(SidebarToneSurface(tone: !tile && !active && hovered ? .hover : nil, radius: radius))
            }
        }
        .browserGeometryMarker("sidebarSelection-\(id)", when: active && previewIcons == nil)
        .overlay(alignment: .topTrailing) {
            if tile && hovered {
                Image(systemName: "xmark").font(OrivIcon.close)
                    .foregroundStyle(selectedInk ?? secondaryInk)
                    .padding(.trailing, OrivSpacing.xxs)
                    .frame(width: OrivMacV3.SidebarLayout.pinCloseWidth, height: OrivMacV3.SidebarLayout.pinCloseHeight, alignment: .trailing)
                    .modifier(SidebarToneSurface(tone: hoveredAccessory == .close ? .hover : nil,
                                                 radius: OrivMacV3.Radius.accessory, drawsRim: false))
                    .browserGeometryMarker("sidebarClose-\(id)", when: previewIcons == nil)
            }
        }
        .overlay {
            if tile && !active && hovered && contrast == .increased {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.text, lineWidth: OrivOutline.focus)
            }
        }
    }

    @ViewBuilder private func pinTileSurface(mode: OrivMacV3.AppearanceMode, style: SidebarChromaticStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tileFill = hovered
            ? OrivMacV3.Sidebar.pinHoverFill(mode, solid: style.opaque)
            : OrivMacV3.Sidebar.pinFill(mode, solid: style.opaque && style.black)
        let tile = shape
            .fill(tileFill)
            .overlay {
                if !style.increased, let specular = OrivMacV3.Sidebar.pinTopHighlight(mode) {
                    shape.inset(by: OrivOutline.hairline)
                        .stroke(
                            LinearGradient(colors: [specular, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25)),
                            lineWidth: OrivOutline.hairline
                        )
                }
            }
            .overlay {
                shape.strokeBorder(
                    OrivMacV3.Sidebar.pinBorder(mode, increasedContrast: style.increased),
                    lineWidth: style.increased ? OrivOutline.enhanced : OrivOutline.hairline
                )
            }
        if style.opaque {
            tile
        } else {
            tile.orivV3Shadow(OrivMacV3.Sidebar.pinShadow(mode))
        }
    }

    private var radius: CGFloat {
        OrivMacV3.Radius.row
    }

    private func accessory(_ symbol: String, kind: SidebarRowAccessory, ink: Color) -> some View {
        Image(systemName: symbol)
            .font(kind == .close ? OrivIcon.close : OrivType.caption)
            .foregroundStyle(ink)
            .frame(width: OrivMacV3.SidebarLayout.accessoryVisual, height: OrivMacV3.SidebarLayout.accessoryVisual)
            .modifier(SidebarToneSurface(tone: hoveredAccessory == kind ? .hover : nil,
                                         radius: OrivMacV3.Radius.accessory, drawsRim: !tile))
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: OrivLayout.sidebarBadgeSize, height: OrivLayout.sidebarBadgeSize)
            .foregroundStyle(theme.text)
            .background(theme.surface, in: Circle())
    }

    @ViewBuilder private func favicon(mode: OrivMacV3.AppearanceMode, style: SidebarChromaticStyle, selectedInk: Color?) -> some View {
        let size = rail ? OrivMacV3.SidebarLayout.railFaviconSize
            : (tile ? OrivMacV3.SidebarLayout.pinIconSize : OrivMacV3.SidebarLayout.tabFaviconSize)
        Group {
            if loading {
                SidebarLoadingRing(mode: mode)
            } else if hovered && !active {
                SiteIdentity(url: url, size: size, isPrivate: isPrivate, isSelected: active, sidebarIcon: true,
                             showsSidebarPrivateBadge: rail || tile, previewIcons: previewIcons,
                             sidebarSelectedInk: selectedInk, sidebarMode: mode, sidebarStyle: style)
                    .environment(\.sidebarRowHovered, true)
            } else {
                SiteIdentity(url: url, size: size, isPrivate: isPrivate, isSelected: active, sidebarIcon: true,
                             showsSidebarPrivateBadge: rail || tile, previewIcons: previewIcons,
                             sidebarSelectedInk: selectedInk, sidebarMode: mode, sidebarStyle: style)
            }
        }
        .frame(width: size, height: size)
        .browserGeometryMarker("sidebarFavicon-\(id)", when: previewIcons == nil)
    }
}

struct SidebarLoadingRing: View {
    @Environment(\.browserReduceMotion) private var reduceMotion
    let mode: OrivMacV3.AppearanceMode
    @State private var spinning = false

    var body: some View {
        let animates = Self.animatesRotation(reduceMotion: reduceMotion)
        let rotating = animates && spinning
        ZStack {
            Circle()
                .stroke(OrivMacV3.Sidebar.loadingRingTrack(mode), lineWidth: OrivOutline.focus)
            Circle()
                .trim(from: .zero, to: 0.25)
                .stroke(OrivMacV3.Semantic.accent(mode),
                        style: StrokeStyle(lineWidth: OrivOutline.focus, lineCap: .round))
                .rotationEffect(.degrees(rotating ? 270 : -90))
                .animation(OrivMacV3.Motion.tabLoading(reduceMotion: reduceMotion), value: rotating)
        }
        .frame(width: OrivMacV3.SidebarLayout.loadingRingSize, height: OrivMacV3.SidebarLayout.loadingRingSize)
        .browserGeometryMarker("sidebarLoadingRingStatic", when: !animates)
        .browserGeometryMarker("sidebarLoadingRingSpinning", when: rotating)
        .onAppear { syncSpinning() }
        .onChange(of: reduceMotion) { _, _ in syncSpinning() }
        .onDisappear { spinning = false }
        .accessibilityHidden(true)
    }

    private func syncSpinning() {
        spinning = Self.animatesRotation(reduceMotion: reduceMotion)
    }

    static func animatesRotation(reduceMotion: Bool) -> Bool {
        !reduceMotion && OrivMacV3.Motion.tabLoading(reduceMotion: reduceMotion) != nil
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
    var sidebarNeedsOpaqueChrome: Bool {
        accessibilityReduceTransparency || chromeReduceTransparencyOverride || sidebarContrast == .increased
    }

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

    func swatch(profile: ProfileColor, dark: Bool) -> Color {
        let tokens = Theme.SidebarChromaticTokens.resolve(self, profile: profile, dark: dark, black: false)
        return Theme.hex(tokens.top)
    }
}

enum SidebarGlassOpacity: String, CaseIterable {
    case balanced = "Balanced"
    case high = "High"
    case solid = "Solid"

    static let preferenceKey = "SidebarGlassOpacity"
}

struct MacSidebarGlass: ViewModifier {
    var color: SidebarColor = .graphite
    var profileColor: ProfileColor? = nil
    var isPrivateWindow = false

    @Environment(\.self) private var environment
    @AppStorage(SidebarGlassOpacity.preferenceKey) private var opacity: SidebarGlassOpacity = .balanced
    #if DEBUG
    @Environment(\.sidebarCaptureOpacity) private var captureOpacity
    @Environment(\.sidebarCaptureBackdrop) private var captureBackdrop
    #endif

    private var effectiveOpacity: SidebarGlassOpacity {
        #if DEBUG
        captureOpacity ?? opacity
        #else
        opacity
        #endif
    }

    func body(content: Content) -> some View {
        let mode = OrivMacV3.AppearanceMode.resolve(theme: environment.browserTheme,
                                                    colorScheme: environment.colorScheme,
                                                    isPrivateWindow: isPrivateWindow)
        let style = SidebarChromaticStyle(color: color, profile: profileColor, level: effectiveOpacity,
                                          environment: environment)
        let recipe = OrivMacV3.Sidebar.chromaticSwatches(color: color, profile: profileColor,
                                                         mode: mode, level: effectiveOpacity)
        let shape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.sidebar, style: .continuous)
        surface(content.environment(\.sidebarChromaticStyle, style).clipShape(shape),
                recipe: recipe, shape: shape, style: style)
            .orivV3Shadow(OrivMacV3.Sidebar.elevation(mode))
    }

    @ViewBuilder private func surface(_ content: some View, recipe: OrivMacV3.GlassRecipe,
                                      shape: RoundedRectangle, style: SidebarChromaticStyle) -> some View {
        #if DEBUG
        if let captureBackdrop, !style.opaque, !style.black {
            let effectiveBackdrop = isPrivateWindow ? OrivMacV3.Backdrop.reduced(.private) : captureBackdrop
            content
                .background {
                    ZStack {
                        effectiveBackdrop
                        recipe.tintColor.opacity(recipe.tintOpacity)
                        if let guardColor = recipe.guardColor, recipe.guardOpacity > 0 {
                            guardColor.opacity(recipe.guardOpacity)
                        }
                    }
                    .clipShape(shape)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
                .overlay {
                    shape.strokeBorder(recipe.borderColor, lineWidth: recipe.borderWidth)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
        } else {
            content.orivV3Glass(recipe, in: shape, forceSolid: effectiveOpacity == .solid)
        }
        #else
        content.orivV3Glass(recipe, in: shape, forceSolid: effectiveOpacity == .solid)
        #endif
    }
}

#if DEBUG
extension EnvironmentValues {
    @Entry var sidebarCaptureOpacity: SidebarGlassOpacity? = nil
}
#endif
