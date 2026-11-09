import AppKit
import BrowserCore
import BrowserEngine
import UniformTypeIdentifiers
import WebKit

extension BrowserController {
    func importBookmarks() {
        Task { @MainActor in
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.html]; panel.allowsMultipleSelection = false
            panel.message = "Choose an HTML bookmark export from your other browser. Only links and titles are imported."
            guard await panel.begin() == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 5_000_000 else { throw BookmarkTransferError.tooLarge }
                let parsed = try BookmarkTransfer.parse(Data(contentsOf: url))
                let alert = NSAlert(); alert.messageText = "Import \(parsed.bookmarks.count) bookmark links?"
                alert.informativeText = "Links will be added to Bookmarks. Existing links are skipped. Folders, passwords, history and website data are not imported. \(parsed.skipped) invalid or duplicate entries were skipped."
                alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
                guard !parsed.bookmarks.isEmpty else { browserError = "No supported HTTP or HTTPS bookmark links were found."; return }
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let count = self.session.importBookmarks(parsed.bookmarks)
                browserNotice = "Imported \(count) new bookmark links. Existing bookmark links were retained."
            } catch { browserError = "Bookmarks couldn’t be imported. \(error.localizedDescription)" }
        }
    }
    func exportBookmarks() {
        let data = BookmarkTransfer.export(savedBookmarks)
        Task { @MainActor in
            let panel = NSSavePanel(); panel.allowedContentTypes = [.html]; panel.nameFieldStringValue = "Oriv Bookmarks.html"
            guard await panel.begin() == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { try data.write(to: url, options: .atomic) }
            catch { browserError = "Bookmarks couldn’t be exported. \(error.localizedDescription)" }
        }
    }
    func printPage() {
        guard let tab = session.selectedTab, tab.url != nil, !tab.isLoading else { return }
        let operation = tab.webView.printOperation(with: NSPrintInfo.shared)
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        operation.run()
    }

    func exportPage(asPDF: Bool) {
        guard !isExportingPage, let tab = session.selectedTab, tab.url != nil else { return }
        let revision = tab.documentRevision, title = tab.displayTitle
        isExportingPage = true
        Task { @MainActor in
            defer { isExportingPage = false }
            do {
                let data: Data
                if asPDF { data = try await tab.webView.pdf(configuration: WKPDFConfiguration()) }
                else { data = try await withCheckedThrowingContinuation { continuation in tab.webView.createWebArchiveData { continuation.resume(with: $0) } } }
                guard tab.documentRevision == revision else { browserError = "The page changed while it was being saved. Try again when it has finished loading."; return }
                let panel = NSSavePanel()
                panel.title = asPDF ? "Export page as PDF" : "Save web archive"
                panel.allowedContentTypes = asPDF ? [.pdf] : [UTType(filenameExtension: "webarchive") ?? .data]
                panel.nameFieldStringValue = DownloadManager.safeFilename(title) + (asPDF ? ".pdf" : ".webarchive")
                guard await panel.begin() == .OK, let url = panel.url else { return }
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try data.write(to: url, options: .atomic)
                try DownloadManager.markDownloadedFile(url, source: tab.isPrivate ? nil : tab.url)
            } catch { browserError = "The page couldn’t be saved. \(error.localizedDescription)" }
        }
    }
}
