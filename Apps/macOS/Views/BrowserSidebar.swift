import BrowserEngine
import SwiftUI

struct BrowserSidebar: View {
    @Environment(\.browserTheme) private var theme
    let controller: BrowserController
    var profiles: BrowserProfiles? = nil
    var compact = false
    @State private var search = ""
    @State private var closeOthers: UUID?
    @State private var closeToRight = false
    private var session: BrowserSession { controller.session }
    private var filteredTabs: [BrowserTab] {
        session.tabs.filter { search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(search) || $0.hostname.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group { if compact { rail } else { expanded } }.background(theme.canvas)
    }
    private var rail: some View {
        VStack(spacing: 14) {
            if let profiles { ProfileMenu(profiles: profiles, compact: true, iconOnly: true).frame(width: 26, height: 30) }
            Button { controller.newTab() } label: { Image(systemName: "plus").frame(width: 36, height: 30) }.accessibilityLabel("New tab")
            Button { controller.library = .bookmarks } label: { Image(systemName: "bookmark").frame(width: 36, height: 30) }.accessibilityLabel("Bookmarks")
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(session.orderedTabs) { tab in
                        Button { session.selectTab(tab.id) } label: {
                            Group {
                                if tab.url != nil { SiteIdentity(url: tab.url, size: 26, isPrivate: tab.isPrivate) }
                                else { Image(systemName: tab.isPrivate ? "eyeglasses" : "plus.square.dashed").foregroundStyle(theme.secondaryText).frame(width: 26, height: 26) }
                            }.frame(width: 40, height: 36)
                                .background { if tab.id == session.selectedTabID { SelectedRowBackground(cornerRadius: 8) } }
                        }.help(tab.displayTitle).accessibilityLabel(tab.displayTitle)
                            .accessibilityAddTraits(tab.id == session.selectedTabID ? .isSelected : [])
                            .contextMenu {
                                Button("Close Tab") { controller.requestCloseTab(tab.id) }
                                Button(tab.isPinned ? "Unpin" : "Pin") { session.togglePinned(tab.id) }
                                Button("Reopen Closed Tab") { session.reopenClosedTab() }.disabled(!session.canReopenTab)
                            }
                    }
                }
            }
            Button { controller.library = .downloads } label: { Image(systemName: "arrow.down.circle").frame(width: 36, height: 30) }.accessibilityLabel("Downloads")
            SettingsLink { Image(systemName: "gearshape").frame(width: 36, height: 30) }.accessibilityLabel("Settings")
        }.buttonStyle(ContentButtonStyle()).foregroundStyle(theme.secondaryText).padding(.vertical, 14).padding(.horizontal, 8)
    }
    private var expanded: some View {
        VStack(spacing: 0) {
            if let profiles {
                ProfileMenu(profiles: profiles).fixedSize().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(height: 40)
                if let notice = profiles.notice { Text(notice).font(.caption).foregroundStyle(theme.secondaryText).padding(.horizontal, 18).padding(.bottom, 8) }
            }
            Button { controller.newTab() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus").frame(width: 18)
                    Text("New Tab")
                    Spacer()
                }.font(.system(size: 13)).foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(ContentButtonStyle()).padding(.horizontal, 8).help("New tab (⌘T)")
                .accessibilityIdentifier("newTabButton")

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
                .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 26)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 12).padding(.vertical, 6)
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
            .overlay {
                if filteredTabs.isEmpty {
                    VStack(spacing: 8) {
                        Text("No matching tabs").font(.callout)
                        Button("Clear Search") { search = "" }.buttonStyle(.link)
                    }.foregroundStyle(theme.secondaryText)
                }
            }

            HStack(spacing: 2) {
                ForEach(LibrarySection.allCases) { section in
                    Button { controller.library = section } label: {
                        Image(systemName: section.symbol).font(.system(size: 13)).frame(width: 30, height: 28)
                    }
                    .buttonStyle(ContentButtonStyle()).foregroundStyle(theme.secondaryText)
                    .accessibilityLabel(section.rawValue)
                    .help(section == .bookmarks ? "Bookmarks (⇧⌘B)" : section.rawValue)
                }
                Spacer(minLength: 4)
                SettingsLink { Image(systemName: "gearshape").font(.system(size: 13)).frame(width: 30, height: 28) }
                    .buttonStyle(ContentButtonStyle()).foregroundStyle(theme.secondaryText)
                    .accessibilityLabel("Settings").help("Settings (⌘,)")
            }.padding(.horizontal, 10).padding(.vertical, 8)
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
                    .listRowBackground(Group { if tab.id == session.selectedTabID { SelectedRowBackground().padding(.horizontal, 4) } })
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
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondaryText)
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
        HStack(spacing: 8) {
            if tab.isLoading { ProgressView().controlSize(.mini).frame(width: 18) }
            else if tab.url == nil { Image(systemName: tab.isPrivate ? "eyeglasses" : "plus.square.dashed").foregroundStyle(theme.secondaryText).frame(width: 18) }
            else { SiteIdentity(url: tab.url, size: 18, isPrivate: tab.isPrivate, isSelected: isSelected) }
            Text(tab.displayTitle).font(.system(size: 13, weight: isSelected ? .medium : .regular)).foregroundStyle(theme.text).lineLimit(1)
            Spacer(minLength: 0)
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
