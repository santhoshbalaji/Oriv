import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI

/// A drag is scoped to this controller, so another profile/window cannot move it.
struct SidebarTabTransfer: Codable {
    let id: UUID
    let owner: UUID
}

enum SidebarDropTarget { case tab(UUID), between(UUID, after: Bool), pinned(Bool) }
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
    /// Up to two complete rows, with a full-width tile when there is one pin.
    static func pinRows(count: Int, width: CGFloat) -> [Int] {
        if width < OrivLayout.sidebarPinThreeColumnWidth {
            switch count {
            case ...0: return []
            case 1: return [1]
            case 2, 3: return [2]
            default: return [2, 2]
            }
        }
        return switch count {
        case ...0: []
        case 1...3: [count]
        case 4: [2, 2]
        case 5: [3, 2]
        default: [3, 3]
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
        guard item.owner == controller.sidebarDragID,
              let source = controller.session.tabs.first(where: { $0.id == item.id }) else { return false }
        switch target {
        case .pinned: return !source.isPrivate
        case .tab(let id), .between(let id, _):
            guard let destination = controller.session.tabs.first(where: { $0.id == id }) else { return false }
            return source.id != id && source.isPrivate == destination.isPrivate && source.isPinned == destination.isPinned
        }
    }

    static func drop(_ items: [SidebarTabTransfer], on target: SidebarDropTarget, controller: BrowserController) -> Bool {
        guard items.count == 1, let item = items.first, canDrop(item, on: target, controller: controller) else { return false }
        switch target {
        case .pinned(let pinned): controller.session.moveTab(item.id, intoPinnedSection: pinned)
        case .tab(let id): controller.session.moveTab(item.id, to: id)
        case .between(let id, let after):
            let ordered = controller.session.orderedTabs
            guard let source = ordered.first(where: { $0.id == item.id }) else { return false }
            let peers = ordered.filter { $0.isPrivate == source.isPrivate && $0.isPinned == source.isPinned }
            guard let start = peers.firstIndex(where: { $0.id == item.id }),
                  let end = peers.firstIndex(where: { $0.id == id }) else { return false }
            controller.session.moveTab(item.id, offset: end - start - (start < end ? 1 : 0) + (after ? 1 : 0))
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


    var body: some View {
        let request = !compact && (searchFocused || controller.tabSearchIsFiltering) ? controller.tabSearchRequest : nil
        let tabs = request.map(controller.tabSearchResults) ?? session.orderedTabs
        return VStack(spacing: railLayout ? 6 : 0) {
            VStack(spacing: railLayout ? 6 : 0) {
                profileHeader
                searchField(firstResult: request == nil ? nil : tabs.first?.id)
                if !railLayout && (searchFocused || request != nil) {
                    SidebarSearchScope(controller: controller).padding(.bottom, OrivSpacing.xs)
                }
                if railLayout { newTab }
                if let notice = profiles?.notice, !session.isExternalPrivate, !compact {
                    Text(notice).font(OrivType.caption).foregroundStyle(theme.sidebarSecondaryText(contrast)).padding(.horizontal, OrivSpacing.large)
                }
                NativeSidebarTabs(controller: controller, profiles: profiles, handle: tabList, tabs: tabs, duplicateTitles: SidebarTabs.duplicateTitles(in: tabs), rail: compact, peek: peeking,
                                  expandedWidth: controller.sidebar.expandedWidth, searchRequest: request) { id, right in
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
        .padding(.vertical, OrivSpacing.xs)
    }

    @ViewBuilder private func searchField(firstResult: UUID?) -> some View {
        let request = controller.tabSearchRequest
        if railLayout {
            Button { controller.searchTabs() } label: {
                HStack(spacing: OrivSpacing.small) {
                    Image(systemName: "magnifyingglass").frame(width: 42, height: 36)
                    if peeking { Text(OrivStrings.searchTabs).modifier(SidebarLabelFade()); Spacer() }
                }
            }.frame(width: compact ? MacBrowserLayout.railItemWidth : nil)
                .buttonStyle(SidebarToneButtonStyle()).focused($utilityFocus, equals: "search")
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
            .padding(.bottom, OrivSpacing.small)
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
        return Button { controller.newTab(isPrivate: isPrivate) } label: {
            HStack(spacing: OrivSpacing.small) {
                Image(systemName: "plus").frame(width: railLayout ? 42 : 19)
                if peeking { Text(title).modifier(SidebarLabelFade()); Spacer() }
                if !railLayout { Text(title); Spacer(); Text("⌘T").font(OrivType.caption).foregroundStyle(theme.sidebarSecondaryText(contrast)) }
            }.font(OrivType.body).padding(.horizontal, railLayout ? 0 : MacBrowserLayout.sidebarRowInset).frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(SidebarToneButtonStyle()).frame(width: compact ? MacBrowserLayout.railItemWidth : nil)
            .padding(.horizontal, peeking ? MacBrowserLayout.railInset : 0)
            .browserGeometryMarker("sidebarNewTabGeometry")
            .focused($utilityFocus, equals: "new-tab")
            .accessibilityLabel(title).accessibilityIdentifier(railLayout ? "railNewTabButton" : "newTabButton").help("\(title) (⌘T)")
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
                            .fill(profile.color.sidebarInk(dark: scheme == .dark))
                            .frame(width: OrivSpacing.small, height: OrivSpacing.small)
                            .padding(OrivSpacing.xxs)
                            .overlay {
                                if selected || contrast == .increased {
                                    Circle().strokeBorder(theme.text, lineWidth: OrivOutline.hairline)
                                }
                            }
                            .frame(width: ProfileDotsScrollMetrics.itemWidth, height: OrivTarget.macMinimum.height)
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
        .frame(height: OrivTarget.macMinimum.height)
        .browserGeometryMarker("sidebarProfileDotsGeometry")
    }

    private var footer: some View {
        VStack(spacing: OrivSpacing.xs) {
            Rectangle().fill(contrast == .increased ? theme.text : theme.separator)
                .frame(height: contrast == .increased ? OrivOutline.enhanced : OrivOutline.hairline)
                .accessibilityHidden(true)
            if railLayout {
                VStack(spacing: OrivSpacing.xxs) { footerButtons }
                    .padding(.bottom, OrivSpacing.small)
            } else {
                HStack(spacing: OrivSpacing.xs) { footerButtons }
                    .frame(height: OrivLayout.sidebarFooterHeight)
            }
        }
        .padding(.horizontal, railLayout ? MacBrowserLayout.railInset : 0)
        .foregroundStyle(theme.sidebarSecondaryText(contrast))
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
        if !railLayout { Spacer(minLength: 0) }
        SettingsLink { footerLabel("Settings", symbol: "gearshape") }
            .buttonStyle(SidebarToneButtonStyle())
            .focused($utilityFocus, equals: "settings")
            .modifier(SidebarFocusRing(visible: utilityFocus == "settings" && controller.sidebar.showsUtilityKeyboardFocus))
            .accessibilityLabel("Settings").help("Settings (⌘,)")
            .browserGeometryMarker("sidebarFooter-Settings")
    }

    private func footerLabel(_ title: String, symbol: String, activeDownload: Bool = false) -> some View {
        HStack(spacing: OrivSpacing.small) {
            Image(systemName: symbol).font(.system(size: OrivIcon.footer))
                .frame(width: railLayout ? MacBrowserLayout.railItemWidth : OrivLayout.controlHeight,
                       height: railLayout ? MacBrowserLayout.railItemHeight : OrivLayout.controlHeight)
                .overlay(alignment: .topTrailing) {
                    if activeDownload {
                        Circle().fill(theme.accent)
                            .frame(width: OrivLayout.sidebarDownloadBadgeSize, height: OrivLayout.sidebarDownloadBadgeSize)
                            .padding(OrivSpacing.xs)
                            .accessibilityHidden(true)
                    }
                }
            if peeking { Text(title).modifier(SidebarLabelFade()); Spacer(minLength: 0) }
        }
        .contentShape(Rectangle())
    }

}

private enum ProfileDotsScrollMetrics {
    static let itemWidth = OrivTarget.macMinimum.width
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
        let secondary = theme.sidebarSecondaryText(contrast)
        SectionHeader(title: title, kind: .sidebar, count: count,
                      symbol: title == "Private" ? "eyeglasses" : nil,
                      symbolInk: theme.sidebarPrivateAccent,
                      ink: secondary,
                      countInk: secondary)
        .browserGeometryMarker("sidebarSection-\(title)", when: marksGeometry)
        .padding(.horizontal, MacBrowserLayout.sidebarRowInset).frame(height: OrivLayout.sidebarSectionHeight)
        .padding(.top, title == "Pinned" || title == "Pin tab" ? 0 : OrivSpacing.xs)
    }
}

struct SidebarToneSurface: ViewModifier {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureTransparency
    @Environment(\.sidebarContrast) private var contrast
    let tone: Theme.SidebarTone?
    var radius = OrivRadius.control

    func body(content: Content) -> some View {
        let opaque = reduceTransparency || captureTransparency || contrast == .increased || theme.isT3Code
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: radius)
        content.background {
            if let tone {
                shape.fill(tone.fill(in: theme, dark: dark, opaque: opaque))
                    .overlay {
                        shape.strokeBorder(theme.sidebarRim(dark: dark, opaque: opaque),
                                           lineWidth: contrast == .increased ? OrivOutline.enhanced : OrivOutline.hairline)
                    }
            }
        }
    }
}

struct SidebarToneButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .modifier(SidebarToneSurface(tone: configuration.isPressed ? .selection : hovered ? .hover : nil))
                .onHover { hovered = $0 }
        }
    }
}

struct SidebarFocusRing: ViewModifier {
    @Environment(\.browserTheme) private var theme
    var visible: Bool

    func body(content: Content) -> some View {
        content.focusEffectDisabled().overlay {
            if visible {
                RoundedRectangle(cornerRadius: OrivRadius.control)
                    .strokeBorder(theme.accent, lineWidth: OrivOutline.focus)
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
    @Environment(\.dynamicTypeSize) private var textSize
    private let tab: BrowserTab?
    private let record: TabRecord?
    private let previewIsPrivate: Bool
    private let id: UUID
    private var title: String { tab?.displayTitle ?? record?.title ?? "" }
    private var url: URL? { tab?.url ?? record?.url }
    private var pinLabel: String {
        guard let site = SiteMonogram.label(for: url?.host()) else { return title }
        return title.caseInsensitiveCompare(site) == .orderedSame ? title : site.capitalized
    }
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
    #if DEBUG
    @Environment(\.sidebarCaptureState) private var captureState
    #endif

    init(tab: BrowserTab, selected: Bool, active: Bool, tile: Bool, rail: Bool, peek: Bool,
         hovered: Bool, hoveredAccessory: SidebarRowAccessory? = nil, subtitle: String?) {
        self.tab = tab; id = tab.id; record = nil; previewIsPrivate = false
        self.selected = selected; self.active = active; self.tile = tile; self.rail = rail
        self.peek = peek; self.hovered = hovered; self.hoveredAccessory = hoveredAccessory; self.subtitle = subtitle
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
        HStack(spacing: OrivSpacing.small) {
            if rail {
                favicon.frame(width: 42, height: 36)
                    .overlay(alignment: .bottomTrailing) {
                        if let mediaSymbol { badge(mediaSymbol) }
                    }
                if peek { Text(title).font(OrivType.body).lineLimit(1); Spacer(minLength: 0) }
            } else if tile {
                VStack(spacing: OrivSpacing.xs) {
                    favicon
                    Text(pinLabel)
                        .font(active ? OrivType.sectionLabel : OrivType.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                favicon
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(textSize.isAccessibilitySize ? .system(size: 26, weight: active ? .medium : .regular)
                              : (active ? OrivType.bodyEmphasized : OrivType.body))
                        .lineLimit(subtitle == nil && textSize.isAccessibilitySize ? 2 : 1)
                    if let subtitle {
                        Text(subtitle)
                            .font(textSize.isAccessibilitySize ? OrivType.windowTitle : OrivType.caption)
                            .foregroundStyle(theme.sidebarSecondaryText(contrast))
                            .lineLimit(1).truncationMode(.middle)
                            .browserGeometryMarker("sidebarHost-\(id)", when: previewIcons == nil)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    if tab != nil {
                        accessory(mediaSymbol, kind: .audio).browserGeometryMarker("sidebarMedia-\(id)", when: mediaSymbol != nil)
                    }
                    accessory(hovered || selected || active ? "xmark" : nil, kind: .close)
                        .browserGeometryMarker("sidebarClose-\(id)", when: previewIcons == nil)
                }
            }
        }
        .padding(.horizontal, rail ? 0 : MacBrowserLayout.sidebarRowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.text)
        .modifier(SidebarToneSurface(tone: selected ? .selection : hovered ? (tile ? .pinHover : .hover) : tile ? .pin : nil, radius: radius))
        .browserGeometryMarker("sidebarSelection-\(id)", when: active && previewIcons == nil)
        .overlay(alignment: .leading) {
            if active && !tile { SelectionMarker(height: OrivIcon.toolbar, background: theme.sidebar.selection).browserGeometryMarker("sidebarAccent-\(id)", when: previewIcons == nil).padding(.leading, OrivSpacing.xs) }
        }
        .overlay {
            if selected && contrast == .increased {
                RoundedRectangle(cornerRadius: radius).strokeBorder(theme.text, lineWidth: OrivOutline.focus)
            }
        }
    }

    private var radius: CGFloat { rail || tile ? OrivRadius.tile : OrivRadius.control }

    private func accessory(_ symbol: String?, kind: SidebarRowAccessory) -> some View {
        ZStack {
            if let symbol {
                Image(systemName: symbol).font(kind == .close ? OrivIcon.close : OrivType.caption)
                    .foregroundStyle(theme.sidebarSecondaryText(contrast))
            }
        }
        .frame(width: OrivLayout.sidebarAccessoryWidth, height: OrivTarget.macMinimum.height)
        .modifier(SidebarToneSurface(tone: hoveredAccessory == kind ? .hover : nil))
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 12, height: 12)
            .foregroundStyle(theme.text)
            .background(theme.surface, in: Circle())
    }

    private var favicon: some View {
        let size = rail ? OrivLayout.sidebarRailFaviconSize
            : (tile ? OrivLayout.sidebarPinIconSize : OrivLayout.sidebarFaviconSize)
        return ZStack {
            SiteIdentity(url: url, size: size, isPrivate: isPrivate, isSelected: active, sidebarIcon: true,
                         showsSidebarPrivateBadge: rail, previewIcons: previewIcons)
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
        case .balanced: 0.43
        case .high: 0.74
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
    private static let balancedLightGuard = 0.42
    private static let balancedLightTintGuard = 0.45
    private static let balancedDarkGuard = 0.54
    private static let balancedDarkTintGuard = 0.60
    private static let balancedBlackGuard = 0.36
    private static let highDarkGuard = 0.38

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
            let guardOpacity = effectiveOpacity == .balanced
                ? balancedGuard(tinted: tinted)
                : (colorScheme == .dark && !theme.isT3Code ? Self.highDarkGuard : 0)
            edge(content
                .background(backing.opacity(effectiveOpacity.backingOpacity))
                .background(Self.balancedTintGuard.opacity(guardOpacity))
                .background { glass })
        }
    }
    private func balancedGuard(tinted: Bool) -> Double {
        if theme.isT3Code { return Self.balancedBlackGuard }
        if colorScheme == .dark { return tinted ? Self.balancedDarkTintGuard : Self.balancedDarkGuard }
        return tinted ? Self.balancedLightTintGuard : Self.balancedLightGuard
    }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: OrivRadius.card, style: .continuous) }

    private func edge<Surface: View>(_ content: Surface) -> some View {
        content.clipShape(shape)
            .overlay {
                shape.strokeBorder(contrast == .increased ? theme.text : theme.separator,
                                   lineWidth: contrast == .increased ? OrivOutline.enhanced : OrivOutline.hairline)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
    @ViewBuilder private var glass: some View {
        #if DEBUG
        if let captureBackdrop {
            captureBackdrop
        } else {
            liveGlass
        }
        #else
        liveGlass
        #endif
    }

    private var liveGlass: some View {
        shape.fill(.clear).glassEffect(.clear, in: shape)
    }
}

#if DEBUG
extension EnvironmentValues {
    @Entry var sidebarCaptureOpacity: SidebarGlassOpacity? = nil
}
#endif
