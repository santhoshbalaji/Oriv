import BrowserEngine
import SwiftUI

struct BrowserSidebar: View {
    @Environment(\.browserTheme) private var theme
    let controller: BrowserController
    var profiles: BrowserProfiles? = nil
    @State private var search = ""
    @State private var closeOthers: UUID?
    @State private var closeToRight = false
    private var session: BrowserSession { controller.session }
    private var filteredTabs: [BrowserTab] {
        session.tabs.filter { search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(search) || $0.hostname.localizedCaseInsensitiveContains(search) }
    }

    var body: some View { expanded }
    private var expanded: some View {
        VStack(spacing: 0) {
            if let notice = profiles?.notice, !session.isExternalPrivate {
                Text(notice).font(.caption).foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 18).padding(.bottom, OrivSpacing.small)
            }
            Button { controller.newTab() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus").frame(width: 18)
                    Text("New Tab")
                    Spacer()
                }.font(OrivType.body).foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(ContentButtonStyle()).padding(.horizontal, OrivSpacing.small).help("New tab (⌘T)")
                .accessibilityIdentifier("newTabButton").padding(.top, 8)

            if session.tabs.count >= 8 || !search.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText).accessibilityHidden(true)
                    TextField("Search tabs", text: $search).textFieldStyle(.plain)
                        .accessibilityIdentifier("tabSearchField")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 24, height: 24).contentShape(Rectangle()) }
                            .buttonStyle(.plain).foregroundStyle(theme.secondaryText).accessibilityLabel("Clear tab search")
                    }
                }
                .font(OrivType.detail).padding(.horizontal, OrivSpacing.small).frame(height: 26)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, OrivSpacing.medium).padding(.vertical, 6)
            }

            List(selection: Binding(get: { session.selectedTabID }, set: { if let id = $0 { session.selectTab(id) } })) {
                let pinned = filteredTabs.filter { !$0.isPrivate && $0.isPinned }
                let regular = filteredTabs.filter { !$0.isPrivate && !$0.isPinned }
                let privateTabs = filteredTabs.filter(\.isPrivate)
                let grouped = !pinned.isEmpty || !privateTabs.isEmpty
                if !pinned.isEmpty { tabSection("Pinned", tabs: pinned) }
                tabSection(grouped ? "Tabs" : nil, tabs: regular)
                if !privateTabs.isEmpty { tabSection("Private", tabs: privateTabs) }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .accessibilityIdentifier("sidebarTabs")
            .overlay {
                if filteredTabs.isEmpty {
                    BrowserEmptyState("No matching tabs") {
                        Button("Clear Search") { search = "" }.buttonStyle(.link)
                    }
                }
            }

            HStack(spacing: 2) {
                ForEach(LibrarySection.allCases) { section in
                    Button { controller.library = section } label: {
                        Image(systemName: section.symbol).font(OrivType.body).frame(width: 30, height: 28)
                    }
                    .buttonStyle(ContentButtonStyle()).foregroundStyle(theme.secondaryText)
                    .accessibilityLabel(section.rawValue)
                    .help(section == .bookmarks ? "Bookmarks (⇧⌘B)" : section.rawValue)
                }
                Spacer(minLength: 4)
                SettingsLink { Image(systemName: "gearshape").font(OrivType.body).frame(width: 30, height: 28) }
                    .buttonStyle(ContentButtonStyle()).foregroundStyle(theme.secondaryText)
                    .accessibilityLabel("Settings").help("Settings (⌘,)")
            }.padding(.horizontal, 10).padding(.vertical, OrivSpacing.small)
        }
        .onChange(of: session.selectedTabID) { _, newID in
            if let newID, !filteredTabs.contains(where: { $0.id == newID }) { search = "" }
        }
        .confirmationDialog(closeToRight ? "Close tabs to the right?" : "Close other tabs?", isPresented: Binding(get: { closeOthers != nil }, set: { if !$0 { closeOthers = nil } })) {
            Button("Close Tabs", role: .destructive) { if let id = closeOthers { session.closeOtherTabs(id, toRight: closeToRight) }; closeOthers = nil }
        } message: { Text("Pinned tabs and tabs in the other privacy group stay open. Unsaved website forms in closed tabs may be lost.") }
    }

    @ViewBuilder private func tabSection(_ title: String?, tabs: [BrowserTab]) -> some View {
        Section {
            ForEach(tabs) { tab in
                TabRow(tab: tab, isSelected: tab.id == session.selectedTabID) { controller.requestCloseTab(tab.id) }
                    .tag(tab.id)
                    .listRowBackground(Group { if tab.id == session.selectedTabID { SelectedRowBackground().padding(.horizontal, OrivSpacing.xs) } })
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .contextMenu {
                        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin") { session.togglePinned(tab.id) }
                        Button("Duplicate Tab", systemImage: "plus.square.on.square") { session.duplicateTab(tab.id) }
                        Button("Move Up", systemImage: "arrow.up") { session.moveTab(tab.id, offset: -1) }
                        Button("Move Down", systemImage: "arrow.down") { session.moveTab(tab.id, offset: 1) }
                        if tab.url != nil {
                            Button(tab.mediaSuspended ? "Resume Media Playback" : "Pause and Block Media Playback", systemImage: tab.mediaSuspended ? "play" : "pause") { tab.toggleMediaSuspension() }
                        }
                        Divider()
                        Button("Close Tab", systemImage: "xmark") { controller.requestCloseTab(tab.id) }
                        Button("Close Other Tabs") { closeToRight = false; closeOthers = tab.id }
                        Button("Close Tabs to the Right") { closeToRight = true; closeOthers = tab.id }
                        Divider()
                        Button("New Private Tab", systemImage: "eyeglasses") { controller.newTab(isPrivate: true) }
                    }
            }
        } header: {
            if let title {
                Text(title).font(OrivType.caption.weight(.medium)).foregroundStyle(theme.secondaryText)
            }
        }
    }
}

private struct TabRow: View {
    @Environment(\.browserTheme) private var theme
    let tab: BrowserTab
    let isSelected: Bool
    let close: () -> Void
    @State private var hovered = false
    @FocusState private var closeFocused: Bool

    var body: some View {
        HStack(spacing: OrivSpacing.small) {
            PageRowContent(title: tab.displayTitle, url: tab.url, layout: .titleOnly, iconSize: 18,
                           spacing: OrivSpacing.small, titleWeight: isSelected ? .medium : .regular,
                           isPrivate: tab.isPrivate, isSelected: isSelected,
                           isLoading: tab.isLoading, showsNewTabSymbol: true)
            if tab.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(theme.secondaryText).accessibilityLabel("Pinned") }
            if tab.mediaSuspended { Image(systemName: "pause.circle").foregroundStyle(theme.secondaryText).accessibilityLabel("Media paused") }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(theme.secondaryText).focused($closeFocused)
            // Hidden only visually on unselected rows; it stays in the accessibility tree and keyboard order.
            .opacity(hovered || isSelected || closeFocused ? 1 : 0)
            .accessibilityLabel("Close \(tab.displayTitle)").help("Close tab")
        }
        .frame(minHeight: 30).contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help(tab.url?.absoluteString ?? tab.displayTitle)
    }
}

/// The approved Option A sidebar is deliberately opaque, including in light mode.
enum MacSidebarPalette {
    static let background = hex(0x221F26)
    private static func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
    static var theme: Theme {
        Theme(isT3Code: false, accent: hex(0xE3ADC4), canvas: background,
            surface: background, field: hex(0x332F38), chrome: background,
            separator: hex(0x514C58), text: hex(0xF5F5F5), secondaryText: hex(0xA9A5AF),
            selection: hex(0x332F38), thread: hex(0x514C58), accentText: hex(0xE3ADC4))
    }
}
