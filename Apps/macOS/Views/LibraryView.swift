import BrowserCore
import BrowserEngine
import SwiftUI

struct LibraryView: View {
    @Environment(\.browserTheme) private var theme
    let controller: BrowserController
    var profiles: BrowserProfiles? = nil
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
        case .devices: 0
        }
    }
    private var subtitle: String {
        switch section {
        case .bookmarks: count == 0 ? "" : "\(count)"
        case .history: count == 0 ? "" : "\(count)"
        case .downloads: "This session"
        case .devices: "Last synced tabs"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $section) {
                ForEach(LibrarySection.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).padding(.vertical, 3).tag(item)
                }
            }.listStyle(.sidebar).tint(theme.accent).accentColor(theme.accent)
            .scrollContentBackground(.hidden).padding(.top, 12)
            .frame(width: 174).background(theme.canvas)
            Divider()
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(section.rawValue).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)

                if section != .downloads {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText).accessibilityHidden(true)
                        TextField("Search \(section.rawValue.lowercased())", text: $search).textFieldStyle(.plain)
                            .accessibilityIdentifier("librarySearchField")
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(theme.secondaryText).accessibilityLabel("Clear search")
                        }
                    }
                    .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 30).background(theme.field, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 24).padding(.bottom, 12)
                }
                Divider()
                contents.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                if controller.session.canUndoBookmarkRemoval {
                    HStack { Text("Bookmark removed"); Spacer(); Button("Undo") { controller.session.undoBookmarkRemoval() } }.padding(.horizontal, 24).padding(.vertical, 8)
                }
                HStack {
                    if section == .history && count > 0 {
                        Text("Private tabs aren’t included").font(.caption).foregroundStyle(theme.secondaryText)
                        Spacer()
                        Button("Clear History…", role: .destructive) { confirmClear = true }
                    } else if section == .downloads {
                        Text("Downloads are kept for this session").font(.caption).foregroundStyle(theme.secondaryText)
                        Spacer()
                        Button("Clear Finished") { controller.downloads.removeFinished() }
                    } else {
                        Text(section == .bookmarks ? "Save a page with ⌘D" : "Private tabs aren’t included")
                            .font(.caption).foregroundStyle(theme.secondaryText)
                        Spacer()
                    }
                }.padding(.horizontal, 24).frame(height: 48)
            }.background(theme.surface)
        }
        .frame(width: 760, height: 540)
        .onChange(of: section) { _, _ in search = "" }
        .confirmationDialog("Clear browsing history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { controller.session.clearHistory() }
        } message: { Text("This removes your history list. Bookmarks and website login data will remain.") }
    }

    @ViewBuilder private var contents: some View {
        switch section {
        case .devices:
            if let profiles { OtherDeviceTabsView(continuity: profiles.continuity, search: search) { page in dismiss(); profiles.openContinuityPage(page) } }
        case .bookmarks:
            if count == 0 {
                empty("Your useful corners of the web", detail: "Save a page with ⌘D. Find it here whenever you need it.", symbol: "bookmark")
            } else if bookmarks.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                let context = URLDisplay.Context(bookmarks.map { ($0.title, $0.url) })
                List(bookmarks) { bookmark in
                    HStack(spacing: 12) {
                        pageRow(bookmark.title, url: bookmark.url, context: context)
                        Button { controller.session.removeBookmark(bookmark.id) } label: {
                            Image(systemName: "trash").font(.system(size: 11)).frame(width: 24, height: 24)
                        }.buttonStyle(.borderless).foregroundStyle(theme.secondaryText)
                            .accessibilityLabel("Remove bookmark for \(bookmark.title)")
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        case .history:
            if count == 0 {
                empty("Your trail starts here", detail: "Pages you visit appear here so you can find them again.", symbol: "clock.arrow.circlepath")
            } else if history.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                let context = URLDisplay.Context(history.map { ($0.title, $0.url) })
                List(history) { entry in
                    HStack(spacing: 12) {
                        pageRow(entry.title, url: entry.url, context: context)
                        Text(entry.visitedAt, format: .dateTime.month(.abbreviated).day())
                            .font(.caption).foregroundStyle(theme.secondaryText).fixedSize()
                        Button { controller.session.removeHistory(entry.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24) }
                            .buttonStyle(.borderless).foregroundStyle(theme.secondaryText).accessibilityLabel("Remove \(entry.title) from history")
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        case .downloads:
            if controller.downloads.items.isEmpty {
                empty("All your downloads, together", detail: "Save a file from any page to see its progress here.", symbol: "arrow.down.circle")
            } else {
                List(controller.downloads.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.isFailed ? "exclamationmark.triangle" : "doc")
                            .font(.title2).foregroundStyle(theme.secondaryText).frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(item.status).font(.caption).foregroundStyle(theme.secondaryText)
                            if !item.isFinished && item.temporaryURL != nil {
                                if let fraction = item.fractionCompleted { ProgressView(value: fraction).frame(maxWidth: 260) }
                                else { ProgressView().controlSize(.small) }
                                Text(item.totalBytes > 0 ? "\(ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))" : ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file))
                                    .font(.caption).foregroundStyle(theme.secondaryText)
                            }
                            if item.isPrivate { Label("Private download", systemImage: "eyeglasses").font(.caption2).foregroundStyle(theme.secondaryText) }
                        }
                        Spacer()
                        if item.status == "Completed", let url = item.destination {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                                Image(systemName: "magnifyingglass").frame(width: 28, height: 28)
                            }.buttonStyle(.borderless).accessibilityLabel("Show \(item.name) in Finder").help("Show in Finder")
                        } else if item.canResume {
                            Button("Resume") { controller.downloads.resume(item) }.buttonStyle(.borderless)
                            Button("Cancel") { controller.downloads.cancel(item) }.buttonStyle(.borderless)
                        } else if !item.isFinished {
                            if item.temporaryURL != nil { Button("Pause") { controller.downloads.pause(item) }.buttonStyle(.borderless).disabled(item.isCancelling) }
                            Button("Cancel") { controller.downloads.cancel(item) }.buttonStyle(.borderless).disabled(item.isCancelling)
                        }
                    }.padding(.vertical, 8)
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
    }

    private func pageRow(_ title: String, url: URL, context: URLDisplay.Context) -> some View {
        Button {
            controller.session.openSavedPage(url)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                SiteIdentity(url: url, size: 24)
                Text(title.isEmpty ? (url.host() ?? url.absoluteString) : title).font(.system(size: 13)).foregroundStyle(theme.text).lineLimit(1)
                if let host = secondaryLine(title: title, url: url, in: context) {
                    Text(host).font(.system(size: 12)).foregroundStyle(theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2).contentShape(Rectangle())
        }.buttonStyle(ContentButtonStyle()).help(url.absoluteString)
            .accessibilityCustomContent(Text("Address"), Text(verbatim: url.absoluteString))
    }
    private func matches(_ title: String, _ url: URL) -> Bool {
        search.isEmpty || title.localizedCaseInsensitiveContains(search) || url.absoluteString.localizedCaseInsensitiveContains(search)
    }
    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
    }
}
