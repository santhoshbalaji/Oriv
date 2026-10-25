import BrowserCore
import ProductivityKit
import SwiftUI

struct StartPage: View {
    let controller: BrowserController
    let isPrivate: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning."
        case 12..<18: "Good afternoon."
        default: "Good evening."
        }
    }
    private var favorites: [StartShortcut] {
        if controller.savedBookmarks.isEmpty { return StartShortcut.defaults }
        return controller.savedBookmarks.prefix(8).map { StartShortcut(title: $0.title, url: $0.url) }
    }
    private var matches: [BrowserSuggestion] { controller.suggestions(for: query, isPrivate: isPrivate) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    search
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchResults
                    } else if isPrivate {
                        privateExplanation
                    } else {
                        favoritesSection(columns: geometry.size.width >= 720 ? 4 : 2)
                        Divider()
                        if geometry.size.width >= 820 {
                            HStack(alignment: .top, spacing: 32) {
                                continuation.frame(maxWidth: .infinity, alignment: .leading)
                                recentSection.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            continuation
                            recentSection
                        }
                    }
                    footer
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, geometry.size.width < 600 ? 28 : 56)
                .padding(.top, geometry.size.height < 640 ? 32 : 62)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
            }
            .background(Theme.canvas)
        }
        .onChange(of: controller.session.selectedTabID) { _, _ in query = "" }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                if isPrivate {
                    Label("Private browsing", systemImage: "eyeglasses")
                        .font(.callout.weight(.medium)).foregroundStyle(Theme.privateAccent)
                }
                if !isPrivate {
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                }
                Text(isPrivate ? "A little more privacy." : greeting)
                    .font(Theme.editorial(40))
                    .accessibilityAddTraits(.isHeader)
                Text(isPrivate ? "A separate space for this session." : "Browse freely. Keep what matters.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !isPrivate {
                OrivThread().frame(width: 92, height: 78)
            }
        }
    }

    private var search: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .regular)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search the web or enter a website", text: $query)
                .textFieldStyle(.plain).font(.system(size: 16))
                .focused($searchFocused).onSubmit(navigate)
                .accessibilityLabel("Search the web or enter a website")
                .accessibilityIdentifier("startSearchField")
                .onExitCommand { query = ""; searchFocused = false }
            if query.isEmpty {
                Text("↵").font(.system(size: 17)).foregroundStyle(.secondary).accessibilityHidden(true)
            } else {
                Button(action: navigate) { Image(systemName: "arrow.right").frame(width: 28, height: 28) }
                    .buttonStyle(.borderless).accessibilityLabel("Open address or search")
            }
        }
        .padding(.horizontal, 20).frame(height: 62)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(searchFocused ? Theme.accent : Theme.separator.opacity(contrast == .increased ? 1 : 0.45), lineWidth: searchFocused ? 2 : 1)
        }
        .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.035), radius: 16, y: 5)
    }

    private func favoritesSection(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(controller.savedBookmarks.isEmpty ? "Quick links" : "Saved pages")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), alignment: .leading, spacing: 14) {
                ForEach(favorites) { shortcut in
                    Button { controller.navigate(shortcut.url.absoluteString) } label: {
                        HStack(spacing: 10) {
                            SiteIdentity(url: shortcut.url, size: 30)
                            Text(shortcut.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8).padding(.horizontal, 6)
                    }
                    .buttonStyle(ContentButtonStyle()).help(shortcut.url.absoluteString)
                    .accessibilityLabel("Open \(shortcut.title)")
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Recently visited", action: "Show all") { controller.library = .history }
            if controller.session.history.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 24)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pick up where you left off").font(.callout.weight(.medium))
                        Text("Pages you visit will appear here.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.vertical, 14)
            } else {
                VStack(spacing: 4) {
                    ForEach(controller.session.history.prefix(3)) { entry in
                        Button { controller.navigate(entry.url.absoluteString) } label: {
                            HStack(spacing: 12) {
                                SiteIdentity(url: entry.url, size: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(entry.url.host() ?? entry.url.absoluteString).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }.buttonStyle(ContentButtonStyle()).help(entry.url.absoluteString)
                    }
                }
            }
        }
    }

    private var continuation: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Continue your work", action: "Workspace") { controller.showWorkspace() }
            let items = controller.workspace?.items.filter { $0.deletedAt == nil && $0.archivedAt == nil }.prefix(3) ?? []
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "bookmark").font(.system(size: 25, weight: .light)).foregroundStyle(Theme.accent)
                    Text("Give a useful page a next step.").font(Theme.editorial(22))
                    Text("Save with ⌘D. Add a thought, track an action, and return with the context intact.")
                        .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                    Button("Open Workspace", systemImage: "arrow.up.right") { controller.showWorkspace() }
                        .buttonStyle(.glass).padding(.top, 4)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    .background(Theme.surface, in: .rect(cornerRadius: 16))
            } else {
                ForEach(items) { item in
                    Button { controller.showWorkspace(itemID: item.id) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "bookmark").foregroundStyle(Theme.accent).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                                let step = controller.workspace?.steps(for: item.id).first { !$0.isComplete }
                                Text(step?.title ?? (item.purpose.isEmpty ? "Add a thought or next step" : item.purpose))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(ContentButtonStyle())
                }
            }
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From your browser").font(.headline).accessibilityAddTraits(.isHeader)
            if matches.isEmpty {
                Text("Press Return to search the web.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ForEach(matches) { match in
                    Button {
                        if let tabID = match.tabID { controller.session.selectTab(tabID) }
                        else { controller.navigate(match.url.absoluteString) }
                    } label: {
                        HStack(spacing: 12) {
                            SiteIdentity(url: match.url, size: 30, isPrivate: isPrivate)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(match.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text(match.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(match.tabID == nil ? "Open" : "Switch to tab").font(.caption).foregroundStyle(.secondary)
                        }.padding(10).contentShape(Rectangle())
                    }.buttonStyle(ContentButtonStyle())
                }
            }
        }
    }

    private var privateExplanation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Tabs and history stay out of your saved session", systemImage: "clock.badge.xmark")
            Label("Website login data is kept separate", systemImage: "person.crop.circle.badge.checkmark")
            Text("Private browsing doesn’t hide your activity from websites or your network. Files you download are still saved to your Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.callout).padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(spacing: 18) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { footerActions }
                VStack(alignment: .leading, spacing: 12) { footerActions }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private var footerActions: some View {
        Button { controller.newTab(isPrivate: !isPrivate) } label: {
            Label(isPrivate ? "New regular tab" : "New private tab", systemImage: isPrivate ? "plus" : "eyeglasses")
        }
        .buttonStyle(.borderless).font(.caption)
        .help(isPrivate ? "Open a regular tab" : "New private tab (⇧⌘N)")
        Button { controller.session.reopenClosedTab() } label: { Label("Reopen closed tab", systemImage: "arrow.uturn.backward") }
            .buttonStyle(.borderless).font(.caption)
            .disabled(!controller.session.canReopenTab).help("Reopen closed tab (⇧⌘T)")
    }
    private func sectionHeader(_ title: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action, action: perform).buttonStyle(.link).font(.system(size: 12))
        }
    }
    private func navigate() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        controller.navigate(query)
    }
}

private struct StartShortcut: Identifiable {
    var title: String
    var url: URL
    var id: URL { url }
    static let defaults = [
        StartShortcut(title: "Apple", url: URL(string: "https://www.apple.com")!),
        StartShortcut(title: "Wikipedia", url: URL(string: "https://www.wikipedia.org")!),
        StartShortcut(title: "GitHub", url: URL(string: "https://github.com")!),
        StartShortcut(title: "DuckDuckGo", url: URL(string: "https://duckduckgo.com")!)
    ]
}
