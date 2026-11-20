import AppKit
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

struct BrowserSidebar: View {
    private let theme = Theme.sidebar
    @Bindable var controller: BrowserController
    var profiles: BrowserProfiles? = nil
    @State var tabList = SidebarListHandle()
    var profileTrailingInset: CGFloat = 0
    @State private var closeOthers: UUID?
    @State private var closeToRight = false
    @State private var settledQuery = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var utilityFocus: String?
    private var session: BrowserSession { controller.session }
    private var compact: Bool { controller.sidebar.rail }
    private var peeking: Bool { controller.sidebar.peeking }
    private var railLayout: Bool { compact || peeking }
    private var filteredTabs: [BrowserTab] { SidebarTabs.filtered(session.orderedTabs, query: settledQuery) }

    var body: some View { sidebarContent.environment(\.browserTheme, Theme.sidebar) }

    private var sidebarContent: some View {
        let tabs = filteredTabs
        return VStack(spacing: railLayout ? 6 : 0) {
            if !railLayout { profileHeader.focused($utilityFocus, equals: "profile") }
            searchField
            if railLayout { newTab }
            if let notice = profiles?.notice, !session.isExternalPrivate, !compact {
                Text(notice).font(.caption).foregroundStyle(theme.secondaryText).padding(.horizontal, 14)
            }
            NativeSidebarTabs(controller: controller, handle: tabList, tabs: tabs, duplicateTitles: SidebarTabs.duplicateTitles(in: tabs), rail: compact, peek: peeking,
                              searching: !controller.tabSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { id, right in
                closeToRight = right
                closeOthers = id
            }
            if !railLayout { newTab.padding(.bottom, MacBrowserLayout.sidebarFooterGap) }
            footer
        }
        .padding(.horizontal, railLayout ? 0 : MacBrowserLayout.sidebarInset)
        .padding(.bottom, railLayout ? 0 : MacBrowserLayout.sidebarInset)
        .font(.system(size: 14))
        .foregroundStyle(theme.text)
        .transformPreference(SidebarKeyboardFocusKey.self) { $0 = $0 || searchFocused || utilityFocus != nil || tabList.hasFocus }
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
                    .focused($searchFocused).accessibilityLabel("Search tabs").accessibilityIdentifier("tabSearchField")
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
                if !railLayout { Text("New Tab"); Spacer(); Text("⌘T").font(.system(size: 10)).foregroundStyle(theme.secondaryText) }
            }.font(OrivType.body).padding(.horizontal, railLayout ? 0 : MacBrowserLayout.sidebarRowInset).frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(ContentButtonStyle()).frame(width: compact ? 42 : nil)
            .padding(.horizontal, peeking ? MacBrowserLayout.railInset : 0)
            .browserGeometryMarker("sidebarNewTabGeometry")
            .focused($utilityFocus, equals: "new-tab")
            .accessibilityLabel("New Tab").accessibilityIdentifier(railLayout ? "railNewTabButton" : "newTabButton").help("New Tab (⌘T)")
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

struct SidebarSectionHeading: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            if title == "Private" { Image(systemName: "eyeglasses") }
            Text(title)
            Spacer()
            if count > 0 { Text("\(count)").font(.system(size: 11)).monospacedDigit() }
        }
        .font(OrivType.caption.weight(.semibold)).foregroundStyle(Theme.sidebar.secondaryText)
        .browserGeometryMarker("sidebarSection-\(title)")
        .padding(.horizontal, MacBrowserLayout.sidebarRowInset).frame(height: 27)
        .padding(.top, title == "Private" ? 8 : (title == "Tabs" || title == "More pinned tabs" ? 4 : 0))
    }
}

struct SidebarTabArtwork: View {
    private let theme = Theme.sidebar
    @Environment(\.sidebarContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var textSize
    let tab: BrowserTab
    let selected: Bool
    let active: Bool
    let tile: Bool
    let rail: Bool
    let peek: Bool
    let hovered: Bool
    let subtitle: String?
    #if DEBUG
    @Environment(\.sidebarCaptureState) private var captureState
    #endif

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

    private var mediaSymbol: String? {
        if tab.mediaSuspended { return "pause.circle" }
        if tab.isAudioMuted { return "speaker.slash.fill" }
        return audio ? "speaker.wave.2.fill" : nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if rail {
                favicon.frame(width: 42, height: 36)
                    .overlay(alignment: .bottomTrailing) {
                        if let mediaSymbol { badge(mediaSymbol) }
                    }
                    .overlay(alignment: .topTrailing) { if tab.isPrivate { badge("eyeglasses") } }
                if peek { Text(tab.displayTitle).font(OrivType.body).lineLimit(1); Spacer(minLength: 0) }
            } else {
                favicon
                if !tile {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tab.displayTitle)
                            .font(.system(size: textSize.isAccessibilitySize ? 26 : 13, weight: active ? .medium : .regular))
                            .lineLimit(subtitle == nil && textSize.isAccessibilitySize ? 2 : 1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: textSize.isAccessibilitySize ? 17 : 11))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1).truncationMode(.middle)
                                .browserGeometryMarker("sidebarHost-\(tab.id)")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let mediaSymbol {
                        Image(systemName: mediaSymbol)
                            .font(.system(size: 11)).foregroundStyle(theme.accentText)
                            .frame(width: 24, height: 24).padding(.leading, -8)
                            .browserGeometryMarker("sidebarMedia-\(tab.id)")
                    }
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText).frame(width: 24, height: 24).padding(.leading, -8)
                        .opacity(hovered || selected || active ? 1 : 0)
                        .browserGeometryMarker("sidebarClose-\(tab.id)")
                }
            }
        }
        .padding(.horizontal, rail || tile ? 0 : MacBrowserLayout.sidebarRowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.text)
        .background(selected ? theme.selection : (hovered ? theme.thread : (tile && !rail ? theme.field.opacity(0.6) : .clear)),
                    in: .rect(cornerRadius: radius))
        .browserGeometryMarker("sidebarSelection-\(tab.id)", when: active)
        .overlay(alignment: .leading) {
            if active { SelectionMarker(height: 16).browserGeometryMarker("sidebarAccent-\(tab.id)").padding(.leading, 1) }
        }
        .overlay {
            if selected && contrast == .increased {
                RoundedRectangle(cornerRadius: radius).strokeBorder(theme.text, lineWidth: 2)
            }
        }
    }

    private var radius: CGFloat { rail ? 10 : (tile ? 12 : 9) }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 12, height: 12)
            .background(theme.surface, in: Circle())
    }

    private var favicon: some View {
        let size: CGFloat = rail ? 22 : (tile ? 24 : 19)
        return ZStack {
            SiteIdentity(url: tab.url, size: size, isPrivate: tab.isPrivate, isSelected: active, sidebarIcon: true)
                .browserGeometryMarker("sidebarFavicon-\(tab.id)")
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

/// A single system glass surface, never one effect per tab. A contrast backing
/// above the glass bounds even its brightest/darkest sampled pixels, so theme
/// text cannot become white-on-light-grey when the page and system differ.
/// check-contrast.py reads these constants to test the composited backgrounds.
struct MacSidebarGlass: ViewModifier {
    // Bounds the sampled glass behind fixed sidebar text in both appearances.
    static let backingOpacity = 0.83
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
