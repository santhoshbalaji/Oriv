import BrowserCore
import SwiftUI

struct LibraryView: View {
    let controller: BrowserController
    @State var section: LibrarySection
    @State private var search = ""
    @State private var confirmClear = false
    @Environment(\.dismiss) private var dismiss

    private var bookmarks: [Bookmark] { controller.savedBookmarks.filter { matches($0.title, $0.url) } }
    private var history: [HistoryEntry] { controller.session.history.filter { matches($0.title, $0.url) } }
    private var count: Int {
        switch section {
        case .bookmarks: controller.savedBookmarks.count
        case .history: controller.session.history.count
        case .downloads: controller.downloads.items.count
        }
    }
    private var subtitle: String {
        switch section {
        case .bookmarks: "\(count) saved \(count == 1 ? "page" : "pages")"
        case .history: "\(count) recently visited \(count == 1 ? "page" : "pages")"
        case .downloads: "Files from this session"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                OrivIdentity(subtitle: "Library").padding(.horizontal, 16).padding(.top, 24)
                List(selection: $section) {
                    ForEach(LibrarySection.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol).padding(.vertical, 5).tag(item)
                    }
                }.listStyle(.sidebar)
            }
            .frame(width: 174).background(.bar)
            Divider()
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.rawValue).font(Theme.editorial(28)).accessibilityAddTraits(.isHeader)
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                }.padding(24)

                if section != .downloads {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Search \(section.rawValue.lowercased())", text: $search).textFieldStyle(.plain)
                            .accessibilityIdentifier("librarySearchField")
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                        }
                    }
                    .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    .padding(.horizontal, 24).padding(.bottom, 16)
                }
                Divider()
                contents.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    if section == .history && count > 0 {
                        Text("Private tabs aren’t included").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear history…", role: .destructive) { confirmClear = true }
                    } else {
                        Text(section == .bookmarks ? "Save a page with ⌘D" : "Choose a location when you save a file")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }.padding(.horizontal, 24).frame(height: 48)
            }.background(Theme.surface)
        }
        .frame(width: 760, height: 540)
        .onChange(of: section) { _, _ in search = "" }
        .confirmationDialog("Clear browsing history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { controller.session.clearHistory() }
        } message: { Text("This removes your history list. Bookmarks and website login data will remain.") }
    }

    @ViewBuilder private var contents: some View {
        switch section {
        case .bookmarks:
            if count == 0 {
                empty("Your useful corners of the web", detail: "Save a page with ⌘D. Find it here whenever you need it.", symbol: "bookmark")
            } else if bookmarks.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(bookmarks) { bookmark in
                    HStack(spacing: 12) {
                        pageRow(bookmark.title, url: bookmark.url)
                        Button { dismiss(); controller.showWorkspace(itemID: bookmark.id) } label: {
                            Image(systemName: "sidebar.right").frame(width: 28, height: 28)
                        }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            .accessibilityLabel("Open saved context for \(bookmark.title)")
                    }.padding(.vertical, 4)
                }.listStyle(.inset)
            }
        case .history:
            if count == 0 {
                empty("Your trail starts here", detail: "Pages you visit appear here so you can find them again.", symbol: "clock.arrow.circlepath")
            } else if history.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(history) { entry in
                    HStack(spacing: 12) {
                        pageRow(entry.title, url: entry.url)
                        Text(entry.visitedAt, format: .dateTime.month(.abbreviated).day())
                            .font(.caption).foregroundStyle(.secondary).fixedSize()
                    }.padding(.vertical, 4)
                }.listStyle(.inset)
            }
        case .downloads:
            if controller.downloads.items.isEmpty {
                empty("All your downloads, together", detail: "Save a file from any page to see its progress here.", symbol: "arrow.down.circle")
            } else {
                List(controller.downloads.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.isFailed ? "exclamationmark.triangle" : "doc")
                            .font(.title2).foregroundStyle(.secondary).frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(item.status).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.status == "Completed", let url = item.destination {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                                Image(systemName: "magnifyingglass").frame(width: 28, height: 28)
                            }.buttonStyle(.borderless).accessibilityLabel("Show \(item.name) in Finder").help("Show in Finder")
                        } else if !item.isFinished {
                            Button("Cancel") { controller.downloads.cancel(item) }.buttonStyle(.borderless)
                        }
                    }.padding(.vertical, 8)
                }.listStyle(.inset)
            }
        }
    }

    private func pageRow(_ title: String, url: URL) -> some View {
        Button {
            controller.session.addTab(url: url)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                SiteIdentity(url: url, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(url.host() ?? url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).help(url.absoluteString)
    }
    private func matches(_ title: String, _ url: URL) -> Bool {
        search.isEmpty || title.localizedCaseInsensitiveContains(search) || url.absoluteString.localizedCaseInsensitiveContains(search)
    }
    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
    }
}
