import BrowserEngine
import SwiftUI

struct BrowserSidebar: View {
    let controller: BrowserController
    @State private var search = ""
    private var session: BrowserSession { controller.session }
    private var filteredTabs: [BrowserTab] {
        session.tabs.filter { search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(search) || $0.hostname.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                OrivIdentity()
                Spacer()
                Button { search = ""; controller.newTab() } label: {
                    Image(systemName: "plus").font(.system(size: 13))
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .accessibilityLabel("New tab").help("New tab (⌘T)")
                .accessibilityIdentifier("newTabButton")
                Menu {
                    Button("New tab", systemImage: "plus") { controller.newTab() }
                    Button("New private tab", systemImage: "eyeglasses") { controller.newTab(isPrivate: true) }
                    Divider()
                    Button("Reopen closed tab", systemImage: "arrow.uturn.backward") { session.reopenClosedTab() }
                        .disabled(!session.canReopenTab)
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Tab actions").help("Tab actions")
            }
            .frame(height: 36)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 18)

            Button { controller.showWorkspace() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.stack").font(.system(size: 16)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Workspace").font(.system(size: 13, weight: .semibold))
                        Text("Saved context & next steps").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.07), in: .rect(cornerRadius: 12))
            }.buttonStyle(ContentButtonStyle()).padding(.horizontal, 12).padding(.bottom, 18)
                .help("Open Workspace (⇧⌘B)")

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search tabs", text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("tabSearchField")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .frame(width: 20, height: 20)
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear tab search")
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 28)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12).padding(.bottom, 8)

            List(selection: Binding(get: { session.selectedTabID }, set: { if let id = $0 { session.selectTab(id) } })) {
                tabSection("Tabs", tabs: filteredTabs.filter { !$0.isPrivate })
                if filteredTabs.contains(where: \.isPrivate) {
                    tabSection("Private tabs", tabs: filteredTabs.filter(\.isPrivate))
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if filteredTabs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.title2)
                        Text("No matching tabs").font(.callout)
                        Button("Clear search") { search = "" }.buttonStyle(.link)
                    }.foregroundStyle(.secondary)
                }
            }

            Divider().padding(.horizontal, 12)
            HStack(spacing: 4) {
                Text("Browse").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ForEach(LibrarySection.allCases.filter { $0 != .bookmarks }) { section in
                    Button { controller.library = section } label: {
                        Image(systemName: section.symbol).font(.system(size: 14))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(ContentButtonStyle())
                    .accessibilityLabel(section == .bookmarks ? "Workspace" : section.rawValue)
                    .help(section == .bookmarks ? "Workspace (⇧⌘B)" : section.rawValue)
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .onChange(of: session.selectedTabID) { _, newID in
            if let newID, !filteredTabs.contains(where: { $0.id == newID }) { search = "" }
        }
    }

    @ViewBuilder private func tabSection(_ title: String, tabs: [BrowserTab]) -> some View {
        Section {
            ForEach(tabs) { tab in
                TabRow(tab: tab, isSelected: tab.id == session.selectedTabID) { session.closeTab(tab.id) }
                    .tag(tab.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .contextMenu {
                        Button("Duplicate tab", systemImage: "plus.square.on.square") { session.duplicateTab(tab.id) }
                        Button("Close tab", systemImage: "xmark") { session.closeTab(tab.id) }
                        Divider()
                        Button("New private tab", systemImage: "eyeglasses") { controller.newTab(isPrivate: true) }
                    }
            }
        } header: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(tabs.count)").monospacedDigit().foregroundStyle(.tertiary)
                Spacer()
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.trailing, 8)
        }
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let isSelected: Bool
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if tab.isLoading { ProgressView().controlSize(.small).frame(width: 24) }
            else { SiteIdentity(url: tab.url, size: 24, isPrivate: tab.isPrivate) }
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayTitle).font(.system(size: 12, weight: isSelected ? .semibold : .regular)).lineLimit(1)
                if tab.url != nil { Text(tab.hostname).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 24, height: 28)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .accessibilityLabel("Close \(tab.displayTitle)").help("Close tab")
        }
        .frame(minHeight: 42).contentShape(Rectangle())
        .help(tab.url?.absoluteString ?? tab.displayTitle)
    }
}
